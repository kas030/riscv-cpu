---
title-meta: RISC-V CPU 设计报告
cover: design-report-cover.pdf
---

# 项目概述

## 项目背景

本项目是全国大学生集成电路创新创业大赛“竞业达”企业命题的参赛设计。赛题要求在 FPGA 数字孪生平台上实现一款 RISC-V 处理器，正确执行 RV32I 指令和指定测试程序，并通过 LED、数码管和计时器显示运行结果。

处理器采用 32 位小端 RISC-V 架构，运行无操作系统的裸机程序。除了比赛要求的 RV32I 基础指令，当前 RTL 还支持 RV32M、项目测试所需的 Zicsr 指令和机器模式异常返回。设计时主要考虑流水线吞吐率、同步存储器时序与 FPGA 工作频率。

## 设计目标

设计目标如下：

1. 正确实现比赛要求的 37 条 RV32I 基础整数指令；
2. 支持 RV32M 全部 8 条乘除法指令，并处理除零和有符号除法溢出；
3. 支持最小 Zicsr/M-mode trap 子集，满足裸机异常入口和返回需求；
4. 在保持顺序提交的前提下，每拍最多发射和提交两条指令；
5. 通过前递、冒险检测、分支预测和小容量缓存降低流水线停顿；
6. 保持 CPU 顶层接口和 SoC 地址映射不变，使仿真模型与板级工程使用相同的接口时序。

## 设计平台

- FPGA 平台：竞业达 FPGA 数字孪生平台；
- 目标器件：Xilinx Kintex-7 XC7K325T-FFG900-2；
- 开发工具：AMD Vivado 2025.2.1；
- 硬件描述语言：SystemVerilog；
- RTL 仿真工具：Verilator 5.020、Vivado XSim 和 Icarus Verilog；
- 软件工具链：RISC-V GNU Toolchain GCC 13.2.0，目标为 `rv32im_zicsr/ilp32`；
- 板级时钟：200 MHz 差分输入，PLL 生成 240 MHz CPU 时钟和 50 MHz 外设时钟。

# RISC-V CPU 架构设计

## RV32I 指令集支持情况

设计已覆盖比赛基础考核涉及的 37 条 RV32I 指令。`fence` 和 `ebreak` 不属于这 37 条指令，`ecall` 则由机器模式 trap 通路处理。

| 类别 | 指令 | 数量 |
| --- | --- | ---: |
| 高位立即数 | `lui`、`auipc` | 2 |
| 跳转 | `jal`、`jalr` | 2 |
| 条件分支 | `beq`、`bne`、`blt`、`bge`、`bltu`、`bgeu` | 6 |
| Load | `lb`、`lh`、`lw`、`lbu`、`lhu` | 5 |
| Store | `sb`、`sh`、`sw` | 3 |
| 立即数运算 | `addi`、`slti`、`sltiu`、`xori`、`ori`、`andi`、`slli`、`srli`、`srai` | 9 |
| 寄存器运算 | `add`、`sub`、`sll`、`slt`、`sltu`、`xor`、`srl`、`sra`、`or`、`and` | 10 |
| 合计 |  | **37** |

Table: RV32I 基础指令支持范围

算术结果按 32 位回绕，移位量取低 5 位；`x0` 恒为零，`jalr` 目标地址的最低位清零。设计只保证自然对齐访存，暂不处理非法指令、未对齐访问和总线访问故障异常。

## CPU 整体架构

CPU 源码按 IF、ID、EX、MEM 和 WB 五类模块组织，不过实际的流水边界是 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`。各级均传递两个槽的数据与控制信号：第一槽沿用普通阶段前缀，第二槽增加 `_S1` 后缀。

\begin{samepage}

\begin{verbatim}
                 +---------------- 分支预测/BHT -----------------+
                 |                                               |
                 v                                               |
+------+   +----------+   +----------+   +----------+   +----------+   +----------+
| PC & |-->|  IF/ID   |-->|  ID/EX   |-->| EX/MEM1  |-->|MEM1/MEM2 |-->| MEM2/WB  |
| IROM |   | 两槽指令 |   | 两槽译码 |   | 两槽结果 |   | 同步返回 |   | 两槽写回 |
+------+   +----------+   +----------+   +----------+   +----------+   +----------+
   ^                         |    ^            |              |              |
   |                         |    +------------+--------------+--------------+
   |                         |          MEM1/MEM2/WB 前递网络
   |                         v
   |                    ALU / RV32M / CSR
   |                         |
   +------ 误预测重定向 -----+

                     EX 地址提前探测 -> 64 项 L0 load 缓存
                                       -> BRAM/MMIO 单数据端口
\end{verbatim}

\end{samepage}

取指端可同时读取 `pc` 和 `pc+4` 对应的两条指令。在双发射提示表命中、当前没有预测跳转，且包内满足配对条件（无 slot0→slot1 RAW、双访存或双 RV32M 冲突）时，两条指令分别进入两个执行槽，PC 前进 8 字节；否则只发射第一槽，PC 前进 4 字节。遇到控制流、CSR、双访存或双 RV32M 组合时，处理器改为单发射。两槽仍按程序顺序提交，第一槽先于第二槽。

valid、stall 和 flush 共同决定流水线状态。出现复位、气泡或错误路径时，硬件会关闭寄存器写、存储器写、CSR 写和控制流重定向，防止无效指令改变处理器状态。

## 数据通路模块设计

### PC 与取指模块

PC 是一个复位值为 `0x80000000` 的 32 位寄存器。IF 级并行计算 `pc+4` 和 `pc+8`，再根据本拍采用单发射还是双发射选择顺序地址。下一 PC 按 EX 重定向、预测目标、顺序地址的次序取值。

取指端设有一张直接映射的双发射提示表。两路组合 IROM 提供两条指令后，硬件判断它们能否配对，并据此训练对应表项；冷启动或 tag 未命中时先按单发射处理。条件分支由 64 项 2 位饱和计数 BHT 预测，尚未训练的分支使用 BTFNT。`jal` 在 IF 级预测跳转，`jalr`、`ecall` 和 `mret` 留到 EX 级解析。

### ALU

ALU 使用 22 位独热控制码，其中低 14 位对应 RV32I 的加减、逻辑、移位和比较操作，高 8 位对应 RV32M。各运算通路并行工作，最后按控制位选出结果。加减与比较共用加法器，分支比较结果则单独输出，无需等待 ALU 汇总完整结果。

Load/store 地址由独立的 `rs1+imm` 加法通路计算，不经过通用 ALU 中的逻辑、移位和比较网络。`auipc` 以 PC 和 U 型立即数为操作数，`lui` 的 U 型立即数则直接送入写回选择。

### 寄存器组

寄存器组有 32 个 32 位通用寄存器，并提供 4 个读端口和 2 个写端口，供两个发射槽使用。硬件忽略对 `x0` 的写入，读取 `x0` 时始终返回 0。

寄存器组支持 WB 到 ID 的同周期旁路。同一拍内，两槽若写入同一个非零寄存器，最终保留较年轻的第二槽结果；其余跨级数据相关交由 EX 前递网络处理。

### 存储器与访存模块

CPU 对外只有一组数据访问接口，因此每拍最多发射一条 load/store。MEM1 从两个槽中选出有效的访存指令，输出地址、写数据和访问尺寸；MEM2 接收同步 BRAM 返回的完整 32 位字；WB 再根据地址低位和 `funct3` 选择 byte/halfword，并完成符号扩展。

Store 请求由 LSU 将访存地址、写数据和 `funct3[1:0]` 送到访存总线，`bram_driver` 根据地址低位和访问尺寸生成 4 位字节写使能及写入数据。数据 BRAM 的地址范围是 `0x80100000` 至 `0x8013FFFF`，容量为 256 KiB。SW、KEY、SEG、LED 和 COUNTER 映射在 `0x80200000` 附近，具体地址以 `perip_bridge.sv` 的译码为准。

访存通路还有一组 64 项直接映射 L0 load 缓存，每项保存一个完整的 BRAM 数据字。Load 在 EX 级查询缓存；若命中，数据可在 MEM1 进入前递通路。MMIO 数据不缓存，store 直接写入 BRAM，同时使相同字地址对应的缓存行失效。

### 其他数据通路模块

RV32M 单元执行 8 条乘除法指令。普通 `mul` 需要一个等待周期，三种高位乘法需要两个等待周期，除法和余数运算迭代 32 次。单元启动时锁存操作数与操作类型；busy 期间，前端和 ID/EX 保持不动。运算完成后，结果沿普通写回和前递通路继续传递。

前递单元分别为两个 EX 槽选择来自 MEM1、MEM2 和 WB 的最新数据，优先级依次为 MEM1、MEM2、WB；若数据来自同一阶段，则第二槽优先。冒险单元检查两个消费者槽是否依赖 ID/EX 或 EX/MEM1 中的 load。L0 未命中时，它会根据数据实际返回的阶段产生 load-use 停顿。

CSR 文件实现了 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`。CSR 旧值有独立的写回来源；`ecall` 和 `mret` 的目标地址通过控制流重定向通路送回 PC。

## 数据通路信号表

| 指令类型 | ALU 输入 A | ALU 输入 B | 运算或地址路径 | 下一 PC | 写回数据 |
| --- | --- | --- | --- | --- | --- |
| R 型 | `rs1` | `rs2` | ALU | `pc+4/pc+8` | ALU 结果 |
| I 型算术 | `rs1` | I 型立即数 | ALU | `pc+4/pc+8` | ALU 结果 |
| Load | `rs1` | I 型立即数 | LSU 地址加法器 | `pc+4/pc+8` | Load 扩展结果 |
| Store | `rs1` | S 型立即数 | LSU 地址加法器 | `pc+4/pc+8` | 无 |
| Branch | `rs1` | `rs2` | 分支比较器 | 预测地址或 EX 重定向 | 无 |
| `jal` | PC | J 型立即数 | 跳转目标加法 | 预测目标 | `pc+4` |
| `jalr` | `rs1` | I 型立即数 | ALU 加法并清除 bit 0 | EX 重定向 | `pc+4` |
| `lui` | 0 | U 型立即数 | 立即数直通 | `pc+4/pc+8` | U 型立即数 |
| `auipc` | PC | U 型立即数 | ALU 加法 | `pc+4/pc+8` | ALU 结果 |

Table: RV32I 各类指令的数据通路选择

写回多路器根据 `MemToReg` 选择数据：`000` 对应 `pc+4`，`001` 对应 ALU/RV32M 结果，`010` 对应 load 数据，`011` 对应 U 型立即数，`100` 对应 CSR 旧值。两个槽共用这套编码。

## 控制器设计

### 控制信号表

| 指令类型 | `NpcOp` | `RegWrite` | `MemToReg` | `MemRead` | `MemWrite` | `ALUSrcA` | `ALUSrcB` |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: |
| R 型/RV32M | `00` | 1 | `001` | 0 | 0 | 0 | 0 |
| I 型算术 | `00` | 1 | `001` | 0 | 0 | 0 | 1 |
| Load | `00` | 1 | `010` | 1 | 0 | 0 | 1 |
| Store | `00` | 0 | `000` | 0 | 1 | 0 | 1 |
| Branch | `01` | 0 | `000` | 0 | 0 | 0 | 0 |
| `jal` | `11` | 1 | `000` | 0 | 0 | 0 | 1 |
| `jalr` | `10` | 1 | `000` | 0 | 0 | 0 | 1 |
| `lui` | `00` | 1 | `011` | 0 | 0 | 0 | 1 |
| `auipc` | `00` | 1 | `001` | 0 | 0 | 1 | 1 |
| Zicsr | `00` | 1 | `100` | 0 | 0 | 0 | 1 |
| `ecall/mret` | `10` | 0 | `000` | 0 | 0 | 0 | 1 |

Table: 各类指令的主要控制信号

`NpcOp=00/01/10/11` 依次表示顺序执行、条件分支、绝对目标类重定向和 `jal`。`OffsetOrigin` 区分普通立即数、`jalr` 的 ALU 结果与 CSR trap 目标。控制信号和 valid 随级间寄存器向后传递，不跨级直接驱动后端副作用。

### 控制器实现

控制器分层完成译码。`main_ctrl` 根据指令生成寄存器写、访存、写回和下一 PC 控制；`imm_gen` 生成 I/S/B/U/J 五类立即数；`alu_ctrl` 根据 `opcode`、`funct3` 和 `funct7` 产生 22 位独热运算码；`csr_ctrl_decode` 识别六种 Zicsr 指令以及 `ecall`、`mret`。`mycpu_decoder` 将这些模块封装在一起，两个槽各实例化一套。

双发射判定会检查 slot0 到 slot1 的 RAW 依赖，以及双访存和双 RV32M 冲突；WAW 不会阻止双发射，同一拍写入同一 `rd` 时，第二槽结果覆盖第一槽。控制流、CSR、双访存及双 RV32M 组合均按单发射执行。EX 级把实际分支结果与预测元数据进行比较；方向或目标不一致时重定向 PC，并冲刷 IF/ID 和 ID/EX，预测正确时则让流水线继续执行。

执行 `ecall` 时，处理器保存异常 PC，写入 `mcause=11`，随后跳转到 `mtvec`；执行 `mret` 时，处理器恢复 `mstatus.MIE/MPIE` 并跳转到 `mepc`。目前尚未实现非法指令、未对齐访问、中断、U/S 模式和完整的 CSR 权限检查。

# CPU 性能优化设计

## 优化项一

第一项优化是双槽顺序发射和访存后端流水化。顺序流水线增加了第二个译码、执行和写回槽。两槽不存在相关或资源冲突时可以同拍推进；无法安全配对时，硬件自动改为单发射。整个过程不需要软件使用专用指令，两槽的提交顺序也没有改变。

同步 BRAM 无法在一个组合 MEM 阶段内完成请求、返回和扩展，因此访存后端分为 MEM1 和 MEM2。MEM1 发出请求，MEM2 接收返回数据，WB 最后处理子字节选择和符号扩展。前递网络覆盖 MEM1、MEM2 与 WB，load-use 检测也会按照数据真正可用的阶段插入停顿。

混合性能微基准共退休 22,273 条指令，运行 21,299 个周期，CPI 为 0.956，平均 IPC 超过 1。在这项负载中，双槽结构利用了程序中的指令级并行性，提高了吞吐率。

## 优化项二

第二项优化集中在控制流、load 相关和关键路径上。条件分支使用 64 项 2 位饱和计数 BHT，尚未训练的分支按 BTFNT 预测。`jal` 在 IF 级预测跳转，只有方向或目标出错时，EX 才会冲刷流水线。64 项 L0 load 缓存在 EX 级提前查询，命中数据可从 MEM1 前递，从而减少紧随 load 的相关停顿。

为适应 240 MHz 的工程配置，IF 同时计算 `pc+4` 和 `pc+8`，并把双发射合法性写入提示表；分支比较结果由 ALU 单独输出，load/store 使用独立的地址加法器，高位乘法增加结果寄存，load 的 lane 选择和扩展则移到 WB。这样可以把 PC 反馈、分支判断、访存返回与乘法结果分散到不同的组合路径中。

综合程序共发出 110,606,978 次 BRAM load，其中 69,677,186 次命中 L0，命中率为 62.995%。Store 采用写穿策略，并在写入时使对应缓存行失效，因此不需要维护脏数据。

## 性能结果汇总

| 测试项目 | 周期数 | 退休指令数 | CPI | 其他结果 |
| --- | ---: | ---: | ---: | --- |
| 混合性能微基准 | 21,299 | 22,273 | 0.956 | IPC 大于 1 |
| 综合矩阵程序 | 404,056,765 | 380,344,360 | 1.062 | L0 命中率 62.995% |

Table: CPU 性能结果摘要

表中的周期、退休指令、CPI、L0 命中率和 COUNTER 均来自 CPU-only 仿真。COUNTER 是 50 MHz 计时器模型的读数，不能直接等同于 FPGA 板级执行时间。

# CPU 特色功能设计

## 特色功能一

第一项特色功能是完整的 RV32M 扩展。RV32M 单元支持 `mul`、`mulh`、`mulhsu`、`mulhu`、`div`、`divu`、`rem` 和 `remu`。普通 `mul` 需要一个等待周期，三种高位乘法需要两个等待周期，普通除法与余数运算迭代 32 次。除数为零时，除法返回全 1，余数返回被除数；只有有符号 `div/rem` 会对 `INT_MIN/-1` 启用溢出快速路径。

RV32M 单元与普通 ALU 相互独立。操作数在启动时锁存；busy 期间，前端和 ID/EX 保持不动。运算完成后，结果沿现有的 MEM1、MEM2、WB 及前递通路继续传递。该单元已通过 8 项定向测试和 8 项 RV32UM 开源参考测试。

## 特色功能二

第二项特色功能是 Zicsr 和机器模式异常返回。CSR 控制器支持 `csrrw/csrrwi`、`csrrs/csrrsi` 与 `csrrc/csrrci`，并实现了 `mstatus`、`mtvec`、`mscratch`、`mepc` 和 `mcause`。软件可先设置 `mtvec`，再通过 `ecall` 进入处理程序；处理程序读取 `mcause` 和 `mepc`、修改返回地址，最后执行 `mret` 返回。

这部分只覆盖项目测试需要的最小机器模式子集，不含中断、PMP、虚拟内存、U/S 模式，也不是完整的特权异常体系。Zicsr 定向测试检查了寄存器源、立即数源、读改写语义和完整的 `ecall/mret` 流程，结果均符合预期。

# 附录

## 代码清单

| 文件或目录 | 主要用途 |
| --- | --- |
| `rtl/core/mycpu.sv` | CPU 顶层，连接双槽流水线、前递、冒险、CSR、L0 和访存接口 |
| `rtl/pipeline/stage/` | IF、ID、EX、MEM1 和 WB 组合逻辑 |
| `rtl/pipeline/register/` | 五组流水级间寄存器 |
| `rtl/control/` | 主译码、ALU/CSR 控制、立即数和重定向控制 |
| `rtl/datapath/` | ALU、PC、寄存器组和 RV32M 单元 |
| `rtl/hazard/` | 双槽 load-use 冒险检测和多级前递 |
| `rtl/memory/` | LSU、load mask、BRAM 驱动和 L0 load 缓存 |
| `rtl/bus/perip_bridge.sv` | BRAM/MMIO 地址译码和板级访存时序 |
| `rtl/soc/student_top.sv` | CPU、双路 IROM 和外设桥连接 |
| `sim_cpu_only/` | Verilator/Icarus CPU-only 仿真环境 |
| `tb/` | Vivado CPU、板级和 UART testbench |
| `verification/` | CPU-only 测试入口、镜像和回归工具 |
| `vivado/tests/` | 分层汇编测试、链接脚本和镜像生成工具 |

Table: 关键源码与验证文件

## 工程目录结构

```text
riscv-cpu-remote/
├── rtl/
│   ├── core/              CPU 核心顶层
│   ├── pipeline/          流水级与级间寄存器
│   ├── control/           指令译码与控制
│   ├── datapath/          ALU、寄存器组和 RV32M
│   ├── hazard/            冒险检测与前递
│   ├── memory/            LSU、BRAM 与 L0 缓存
│   ├── bus/               外设桥和地址译码
│   ├── soc/               SoC 连接层
│   └── top/               FPGA 板级顶层
├── sim_cpu_only/          CPU-only 仿真环境
├── verification/          CPU 测试和回归工具
├── tb/                    Vivado testbench
├── vivado/tests/          汇编测试与镜像工具
├── ip/                    IROM、BRAM 和 PLL 配置
├── constraints/           板级约束
├── scripts/               Vivado 自动化脚本
└── docs/                  设计报告与测评报告
```

## 参考资料

1. RISC-V International. *The RISC-V Instruction Set Manual, Volume I: Unprivileged ISA*.
2. RISC-V International. *The RISC-V Instruction Set Manual, Volume II: Privileged Architecture*.
3. AMD. *Vivado Design Suite User Guide: Synthesis (UG901)*.
4. IEEE. *IEEE Standard for SystemVerilog, IEEE Std 1800-2017*.

## AI 工具声明

本文使用 AI 工具对文档部分内容进行润色。RTL、测试程序、实验数据及技术结论均由我们核对。
