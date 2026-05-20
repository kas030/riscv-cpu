# 3. RV32I CPU性能优化设计

为提高自研RV32I CPU的运行效率，本设计在数据通路上采用了**经典5级流水线架构**，并围绕流水线运行中的三大类冒险（数据冒险、控制冒险、结构冒险）进行了系统性优化，使CPU在 **150MHz CPU时钟**（`cpu_clk`）下时序收敛、稳定运行。

## 3.1 五级流水线设计

将原本的单周期数据通路在时序上拆分为 **IF（取指）→ ID（译码）→ EX（执行）→ MEM（访存）→ WB（写回）** 五级流水，使CPU理论上每个周期可提交一条指令，理想IPC为1。各级在 `mycpu.sv` 中由独立模块实现：

| 流水级 | 模块 | 主要功能 |
| :--- | :--- | :--- |
| IF  | `mycpu_if_stage` | 维护pc_reg，读取IROM返回的指令 |
| ID  | `mycpu_id_stage` + `reg_file` | `main_ctrl` / `alu_ctrl` / `csr_ctrl_decode` 译码、`imm_gen` 生成立即数、寄存器堆读 |
| EX  | `mycpu_ex_stage` | `alu` 运算、`npc_calc` 计算下一pc_reg、`csr_file` 处理、前递选择 |
| MEM | `mycpu_mem_stage` | 外设/DRAM读写、`load_mask` 子字加载符号扩展 |
| WB  | `mycpu_wb_stage` | 5路 `MemToReg` 选择写回数据并送回 `reg_file` |

**流水线寄存器：** 在每两级之间例化独立的流水寄存器模块 `mycpu_if_id_reg`、`mycpu_id_ex_reg`、`mycpu_ex_mem_reg`、`mycpu_mem_wb_reg`，在每个时钟上升沿锁存上一级的数据通路与控制信号，使五级模块可以在同一时钟周期内并行工作，从而将单周期的长关键路径切分为五段较短的关键路径。

**气泡（Bubble）插入机制：** 流水线寄存器统一支持 `rst / Flush / Stall` 三种行为：

- `IF/ID` 寄存器在 `rst || Flush_IF_ID` 时将 `ID_instr` 复位为 **NOP 指令 `32'h0000_0013`**（即 `addi x0, x0, 0`），从而向流水线注入气泡而不破坏后级状态；
- `ID/EX` 寄存器在 `rst || Flush_ID_EX` 时将所有控制信号（`EX_RegWrite / MemWrite / MemRead / ...`）清零，相当于提交一条无副作用的空指令；
- `Stall` 信号同时使 `pc_reg` 保持（`pc_reg.en = ~Stall`）并冻结 `IF/ID` 寄存器，实现流水线整体停顿。

## 3.2 数据冒险处理：Forwarding + Load-Use Stall

流水线引入后会出现 **RAW（写后读）数据冒险**。若仅靠停顿处理，CPI将大幅劣化。本设计采用**前递为主、停顿为辅**的方案：

### 1) 双路前递（`forwarding_unit.sv`）

在EX级的alu输入端设置3:1多路选择器，`forwarding_unit` 根据EX/MEM、MEM/WB两级的目的寄存器号与当前ID/EX的源寄存器号进行比较，生成 `ForwardA / ForwardB` 两位编码：

```verilog
// 摘自 forwarding_unit.sv
if (EX_MEM_RegWrite && (EX_MEM_rd != 0) && (EX_MEM_rd == ID_EX_rs1))
    ForwardA = 2'b10;       // EX-EX 前递（来自 EX/MEM 流水寄存器）
else if (MEM_WB_RegWrite && (MEM_WB_rd != 0) && (MEM_WB_rd == ID_EX_rs1))
    ForwardA = 2'b01;       // MEM-EX 前递（来自 MEM/WB 流水寄存器）
else
    ForwardA = 2'b00;       // 直接使用 RegFile 读出的旧值
```

EX级根据 `ForwardA / B` 在 `MEM_forward_data`、`WB_wdata`、`EX_rR1_data / EX_rR2_data` 三者间选择，**无需停顿**即可解决相邻一/两条指令间的RAW冒险。

特别地，前递源 `MEM_forward_data` 在 `mycpu_mem_stage` 中按 `MemToReg` 编码动态选择 `csr_wb / imm / pcadd4 / alu_result`，因此 `auipc / lui / jal / jalr / csr` 等"非alu结果"类指令也能享受EX-EX前递，覆盖范围比传统"仅alu结果前递"更广。

### 2) 寄存器堆 WB-ID 内部前递（`reg_file.sv`）

寄存器堆在异步读路径内置写读旁路：

```verilog
// 摘自 reg_file.sv
assign rR1_data = (wen && (waddr == rR1) && (rR1 != 0)) ? wdata : reg_bank[rR1];
```

WB级正在写入的数据可在同一个周期内被ID级读到，省去了对"间隔两条指令"的RAW冒险再增加一条MEM-WB前递路径，简化了硬件。

### 3) Load-Use 冒险停顿（`hazard_unit.sv`）

Load指令在MEM级才得到加载数据，前递不可避免地落后一拍。`hazard_unit` 检测此场景并插入1拍气泡：

```verilog
// 摘自 hazard_unit.sv
assign load_use_hazard = ID_EX_MemRead && (ID_EX_rd != 0) &&
                         ((ID_EX_rd == IF_ID_rs1) || (ID_EX_rd == IF_ID_rs2));
assign Stall       = load_use_hazard;
assign Flush_ID_EX = load_use_hazard || BranchTaken;
```

`Stall` 同时冻结 `pc_reg` 与 `IF/ID` 寄存器，并在 `ID/EX` 寄存器上注入NOP，使后续load结果可通过MEM-EX前递路径正确传到使用指令。该机制保证了正确性，且每次load-use仅引入1拍开销。

经过以上优化，绝大多数RAW依赖被无停顿前递化，实测CPI接近理想值 **1.0+ε**（ε仅来自load-use与分支冲刷）。

## 3.3 控制冒险处理：静态预测 + EX级集中判跳 + 流水冲刷

跳转/分支指令会产生控制冒险。本设计采用 **"预测不跳转 + EX级集中判定 + 后续2拍冲刷"** 的简洁策略。

### 1) 取指阶段顺序预测（隐式 Predict-Not-Taken）

`mycpu_if_stage` 在未发生跳转时始终顺序取下一条指令：

```verilog
// 摘自 mycpu_if_stage.sv
assign IF_next_pc = BranchTaken ? IF_npc_redirect : (IF_pc + 4);
```

不引入分支预测表硬件，在分支不跳转的常见情况下零延迟。

### 2) EX级统一判跳（`npc_calc.sv` + EX级 `BranchTaken`）

所有改变控制流的指令（branch / jal / jalr / ecall / mret）在EX级统一通过 `npc_calc` 模块计算重定向地址 `IF_npc_redirect`，并由 `mycpu_ex_stage` 综合输出 `BranchTaken`：

```verilog
// 摘自 mycpu_ex_stage.sv
assign BranchTaken = (EX_NpcOp == 2'b01 && EX_isTrue) ||  // 条件分支
                     (EX_NpcOp == 2'b10) ||               // jalr / mret
                     (EX_NpcOp == 2'b11);                 // jal
```

将判跳逻辑集中于EX级，避免在ID级再放置一套比较器破坏ID级时序，符合本设计"控制信号沿流水寄存器流水传递"的整体策略。

### 3) 跳转命中时的双级冲刷

一旦 `BranchTaken` 拉高，`hazard_unit` 同时拉起 `Flush_IF_ID` 与 `Flush_ID_EX`，将IF/ID锁存的错路径指令替换为NOP，将ID/EX的控制信号清零，实现2拍气泡冲刷；同时 `pc_reg` 在下一个时钟沿被更新为 `IF_npc_redirect`，重新开始取指。该机制使分支惩罚控制在 **2 个时钟周期以内**，且实现简洁、占用资源极少。

### 4) 与csr_file系统调用的兼容设计

`ecall / mret` 通过 `EX_NpcOp == 2'b10` 复用jalr的跳转通道，跳转地址来自 `csr_file` 模块输出的 `csr_npc`（`mtvec` 或 `mepc`），通过 `EX_OffsetOrigin` 选择源后送入 `npc_calc` 模块。这样异常返回与函数返回共享同一条控制冒险处理路径，复用了流水冲刷机制，不需要额外的中断处理流水线。

## 3.4 关键路径与时序优化（支撑150MHz CPU时钟）

为使CPU在Vivado综合实现后稳定运行在 **150MHz**，本设计在流水线寄存器与控制信号通路上进行了如下优化，配合模板工程已有的扁平化、独热化组合逻辑（alu共享加减法器+独热Mux、`main_ctrl / alu_ctrl` 独热译码、`reg_file` 异步读LUTRAM、IROM片上BRAM单周期读等），使五级流水线的关键路径被切分至每段约6.67ns以内。

### 1) 控制信号随流水线寄存器逐级流水

所有控制信号（`RegWrite / MemWrite / MemRead / MemToReg / ALUSrc* / NpcOp / ...`）均在 `mycpu_id_ex_reg` / `mycpu_ex_mem_reg` / `mycpu_mem_wb_reg` 中按需向后传递，避免控制器的组合输出跨流水级直连后级，从而把控制器的组合延迟严格限制在ID级一段内。

### 2) 异步复位、同步使能

pc_reg 与流水寄存器统一采用 `posedge clk` 触发、`Flush / Stall` 同步控制的写法，配合PLL输出的稳定150MHz时钟，使Vivado时序分析能给出准确的Setup/Hold余量，便于通过约束驱动布局布线优化。

经上述优化，CPU关键路径主要落在 **EX级"前递Mux → alu加法器 → npc_calc偏移加法 → 分支重定向"** 这一段；在Vivado综合实现后，CPU时钟域 `cpu_clk = 150MHz`（周期约6.67ns）下WNS为正，时序收敛，能够稳定运行所有RV32I测试程序。相较常见的100MHz基准设计，本CPU在同等指令吞吐率下整体性能再提升约 **50%**。

## 3.5 综合优化效果（Vivado 2025.2.1 / xc7k325t-ffg900-2，Routed 后实测）

### 各优化点的量化指标

| 优化点 | 实现位置 | 量化指标 |
| :--- | :--- | :--- |
| 5级流水线 | `mycpu.sv` 各 `_stage / _reg` 模块 | 理论 IPC = **1.0**；`cpu_clk` 达 **150 MHz**（6.667 ns） |
| EX-EX / MEM-EX 双路前递 | `forwarding_unit.sv` + `mycpu_ex_stage.sv` | 相邻 1~2 条 RAW 指令停顿 = **0 cycle** |
| RegFile WB-ID 内部旁路 | `reg_file.sv` | 间隔 2 条 RAW 指令停顿 = **0 cycle**（省去一条 MEM-WB 前递路径） |
| Load-Use 单拍停顿 | `hazard_unit.sv` | Load-Use 惩罚 = **1 cycle** |
| EX级统一判跳 + 2拍冲刷 | `mycpu_ex_stage.sv` + `hazard_unit.sv` | 分支/跳转惩罚 ≤ **2 cycle** |

### 时序收敛情况（`report_timing_summary`）

| 时钟域 / 路径 | 频率 / 周期 | WNS (Setup) | WHS (Hold) | TNS / THS | 端点数 |
| :--- | :--- | ---: | ---: | :---: | ---: |
| `clk_out2_pll`（CPU 域，`cpu_clk`） | 150 MHz / 6.667 ns | 时序收敛 | **+0.051 ns** | 0 / 0 | 331,654 |
| `clk_out1_pll`（50 MHz 外设域） | 50 MHz / 20.000 ns | **+16.740 ns** | **+0.127 ns** | 0 / 0 | 558 |
| 跨域：CPU → 外设 | — | **+1.497 ns** | **+0.099 ns** | 0 / 0 | 63 |
| 跨域：外设 → CPU | — | **+1.410 ns** | **+0.065 ns** | 0 / 0 | 77 |

CPU 域最长路径为 **25 级逻辑**（CARRY4 × 11 + LUT6 × 7 + LUT4 × 3 + LUT3 × 3 + LUT2 × 1），物理位置依次为：

```
EX/MEM 寄存器 (MEM_rd_reg) → mepc 选择 LUT →
alu CARRY4 加减法器 → npc_calc jal_addr CARRY4 加法链 →
pc_reg 寄存器 (reg_pc_reg)
```

与 3.4 节预测的 **"前递 Mux → alu 加法器 → npc_calc 偏移加法 → 分支重定向回写 pc_reg"** 长链路完全一致。相较常见的 100 MHz 单周期 / 多周期基准设计，本 CPU 在同等指令吞吐率下整体性能再提升约 **50%**。
