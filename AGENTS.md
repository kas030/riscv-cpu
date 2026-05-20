# AGENTS.md

本仓库是一个 Vivado/FPGA 工程中的 RV32I 五级流水 CPU。后续 agent 在分析、
修改或验证代码时，请优先遵循本文约定。

## 项目结构

- `rtl/core/mycpu.sv`：CPU 核心顶层，串接 `IF -> ID -> EX -> MEM -> WB`
  五级流水、流水寄存器、冒险检测、前递和寄存器堆。
- `rtl/pipeline/stage/`：五个流水级实现：
  `mycpu_if_stage`、`mycpu_id_stage`、`mycpu_ex_stage`、
  `mycpu_mem_stage`、`mycpu_wb_stage`。
- `rtl/pipeline/register/`：级间流水寄存器：
  `mycpu_if_id_reg`、`mycpu_id_ex_reg`、`mycpu_ex_mem_reg`、
  `mycpu_mem_wb_reg`。
- `rtl/control/`：译码与控制逻辑，包括 `main_ctrl.sv`、`alu_ctrl.sv`、
  `imm_gen.sv`、`csr_ctrl_decode.sv`、`csr_file.sv`、`npc_calc.sv`。
- `rtl/datapath/`：`alu.sv`、`pc_reg.sv`、`reg_file.sv` 等数据通路基础模块。
- `rtl/hazard/`：`hazard_unit.sv` 与 `forwarding_unit.sv`。
- `rtl/memory/`：DRAM 访问与 load 数据 mask/扩展相关模块。
- `rtl/bus/perip_bridge.sv`：当前 RTL 的 DRAM/MMIO 地址译码权威来源。
- `rtl/soc/student_top.sv`：实例化 `mycpu`、IROM 和 `perip_bridge`。
- `rtl/top/top.sv`：板级顶层，包含 PLL、UART、twin controller 与
  `student_top`。
- `tb/`：CPU/top/UART 的 SystemVerilog testbench。
- `vivado/tests/`：RV32I 汇编测试、链接脚本和 `.coe`/`.mif` 生成工具。
- `ip/`：Vivado IP 描述文件，如 PLL、IROM、DRAM。
- `constraints/`：板级约束文件。

## 架构要点

- CPU 复位入口 PC 在 `rtl/core/mycpu.sv` 中定义为 `32'h8000_0000`。
- `student_top.sv` 使用 `inst_addr = pc[13:2]` 访问 IROM，高位 PC 被有意
  忽略，用于把 `0x8000_0000` 附近的取指映射到 IROM 索引。
- 分支、`jal`、`jalr`、`ecall`、`mret` 均在 EX 级解析。跳转成立时，
  `hazard_unit` 同时冲刷 IF/ID 与 ID/EX。
- load-use 冒险会停顿 PC 与 IF/ID 一拍，并冲刷 ID/EX 注入气泡。
- `forwarding_unit` 产生 EX/MEM 与 MEM/WB 两路前递选择，优先级为
  EX/MEM 高于 MEM/WB。
- `mycpu_mem_stage.sv` 根据 `MemToReg` 预先生成 `MEM_forward_data`，使
  `lui`、`jal`、`jalr`、csr_file 等非普通 ALU 写回值也能走前递路径。
- `reg_file.sv` 内置 WB 到 ID 的同周期旁路，并屏蔽对 `x0` 的写入。
- ALU 使用 14 位一热 `ALUControl`，由 `alu_ctrl.sv` 译码生成。
- 流水寄存器在 reset/flush 时注入 NOP 或清零控制信号。修改冒险、冲刷
  或控制逻辑时必须保持该无副作用气泡语义。

## 地址映射

当前 RTL 行为以 `rtl/bus/perip_bridge.sv` 为准：

- DRAM：`0x8010_0000 <= addr < 0x8013_FFFF`
- SW0：`0x8020_0000`
- SW1：`0x8020_0004`
- KEY：`0x8020_0010`
- SEG：`0x8020_0020`
- LED：`0x8020_0040`
- COUNTER：`0x8020_0050`

注意：`vivado/tests/linker/link.ld` 与部分旧汇编测试中的注释/地址看起来
和当前 `perip_bridge.sv` 不完全一致。涉及测试、链接脚本或外设访问时，
先核对 RTL，再成组调整测试与 testbench。

## 编码约定

- 延续现有 SystemVerilog 风格，优先使用 `logic`、`always_comb`、
  `always_ff`。
- CPU 核心修改边界：`rtl/core/mycpu.sv` 的对外端口列表视为固定接口，
  不允许增删端口、改名、改宽度、改方向或改变接口时序语义。功能实现必须
  接入 `mycpu` 已定义的 IROM 与外设/DRAM 访问接口。
- 除非任务明确要求改 SoC、外设地址映射、板级集成、testbench 或 Vivado
  IP，否则只能修改隶属于 `mycpu` 的 CPU 核心实现模块，例如
  `rtl/core/mycpu.sv` 的内部连线、流水级、流水寄存器、控制、数据通路、
  冒险/前递以及 CPU 内存访问辅助逻辑。不要为了适配 CPU 功能去修改
  `rtl/soc/student_top.sv`、`rtl/top/top.sv`、`rtl/bus/perip_bridge.sv`、
  `tb/`、`constraints/`、`ip/` 或 Vivado 生成目录。
- 流水信号命名保持 `IF_`、`ID_`、`EX_`、`MEM_`、`WB_` 前缀。
- 保持被 testbench 依赖的层次名稳定。例如 `mycpu.sv` 中寄存器堆实例名
  为 `rf_inst`，`tb/tb_myCPU.sv` 会层次化引用它。
- 不要随意把现有一热译码/一热 mux 风格改成大规模无关重构。
- 中文注释较多，文件应保持 UTF-8。新增注释要简洁，解释设计意图或
  易错点即可。
- 不要编辑 Vivado 生成目录、`.runs`、`.cache`、`.sim`、日志或
  `cpu_core_files.md`。
- `.xci` 属于 IP 配置产物，只有在任务明确要求改 Vivado IP 时才修改。

## Commit Message 规范

- 沿用仓库历史中的 Conventional Commits 风格：`type(scope): 中文摘要`。
- `scope` 可省略；涉及明确子系统时使用小写范围，例如 `cpu`、`vivado`。
- 常用 `type`：
  `docs` 文档、`fix` 修复、`feat` 功能、`refactor` 重构、`style` 仅风格或
  注释命名、`chore` 工程维护。
- 摘要使用简短中文动宾短语，说明本次提交做了什么，不以句号结尾。
- 示例：`docs: 添加 5 级流水线 CPU 性能优化设计文档`、
  `fix(cpu): 修正 load-use 冒险冲刷逻辑`。

## 测试与验证

具备 RISC-V 裸机工具链和 Python 3 时，可在 `vivado/tests/` 下生成测试
镜像：

```sh
make
make t10_fibonacci
make clean
```

Makefile 会尝试 `riscv32-unknown-elf-`、`riscv-none-embed-`、
`riscv64-unknown-elf-` 等前缀，生成物位于 `vivado/tests/build/`。

Vivado 仿真入口：

- `tb/tb_myCPU.sv`：CPU/性能测试，带周期、写回、store、taken branch 计数。
- `tb/tb_top.sv`：顶层 UART/twin-controller 集成行为。
- `tb/tb_uart.sv`：独立 UART 行为。

`tb/tb_myCPU.sv` 会引用 `uut.student_top_inst.Core_cpu` 下的内部层次来统计
性能。如果修改顶层层次或实例名，请同步更新 testbench。

`tb/tb_myCPU.sv` 当前等待 `virtual_led` 写入 `32'hC0DEC0DE` 或
`32'hDEADBEEF` 后结束。确保 IROM 中加载的程序遵循同一完成约定；否则 CPU
可能已执行到预期位置，但仿真仍会超时。

## 修改检查清单

- 改指令译码：同步检查 `defines.sv`、`main_ctrl.sv`、`alu_ctrl.sv`、
  `imm_gen.sv`、`csr_ctrl_decode.sv` 与相关汇编测试。
- 新增写回来源：同步更新 `MemToReg` 编码、ID/EX、EX/MEM、MEM/WB、
  `mycpu_mem_stage.sv`、`mycpu_wb_stage.sv`。
- 改冒险/前递：重点验证 `t07_forwarding.S`、`t08_load_use.S`、
  `t09_branch_hazard.S`。
- 改分支/csr_file：检查 `npc_calc.sv`、`csr_file.sv`、`csr_ctrl_decode.sv`、`main_ctrl.sv`，以及
  IF/ID 与 ID/EX 的冲刷行为。
- 改 load/store：同时核对 `load_mask.sv`、`dram_driver.sv`、
  `mycpu_mem_stage.sv`、`perip_bridge.sv` 的宽度、符号扩展、字节偏移和
  地址译码。
- 改顶层：保持 `top.sv`、`student_top.sv`、约束、testbench、Vivado IP 的
  时钟/复位极性一致。

## 已知易错点

- PowerShell 不指定 UTF-8 时可能把中文注释显示成乱码。读写源码时使用
  UTF-8 感知工具。
- 当前仓库可能被 Git 判定为 dubious ownership。除非任务需要 Git 操作，
  不要擅自修改全局 Git 配置。
- 地址映射、链接脚本和旧测试注释之间存在不一致迹象。以当前 RTL 为准，
  再有意识地修正测试侧。
- `load_mask.sv` 与 `dram_driver.sv` 分担了字节/半字选择、符号扩展和读写拼接
  责任；不要只改其中一侧。
- IROM 测试镜像的完成约定必须和 testbench 匹配，否则会出现“CPU 正常跑、
  仿真不结束”的假失败。
