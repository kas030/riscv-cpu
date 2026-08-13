# AGENTS.md

本仓库是一个面向 Vivado/FPGA 的 32 位 RISC-V CPU 工程。当前 CPU 支持 RV32I、RV32M 和项目测试所需的 Zicsr/陷阱返回功能，采用双槽顺序发射，流水后端为 `MEM1/MEM2` 两级。分析、修改或验证代码时，以当前 RTL 和本文约定为准。

## 项目结构

- `rtl/core/mycpu.sv`：CPU 核心顶层，连接双槽流水线、冒险检测、前递、寄存器堆、分支重定向、L0 load 缓存和访存通路。
- `rtl/pipeline/stage/`：`IF`、`ID`、`EX`、`MEM`、`WB` 的组合逻辑。 `mycpu_mem_stage.sv` 对应 MEM1 处理，MEM2 数据由级间寄存器继续传递。
- `rtl/pipeline/register/`：级间寄存器。当前包括 `IF/ID`、`ID/EX`、 `EX/MEM1`、`MEM1/MEM2` 和 `MEM2/WB`。
- `rtl/control/`：主译码、ALU/CSR 控制、立即数生成、下一 PC、统一译码封装和重定向控制。
- `rtl/datapath/`：ALU、PC、双写口寄存器堆和 `rv32m_unit.sv`。
- `rtl/hazard/`：双槽 load-use 冒险检测和多级前递选择。
- `rtl/memory/`：LSU、BRAM 驱动、load mask/扩展和 `load_l0_cache.sv`。
- `rtl/bus/perip_bridge.sv`：BRAM/MMIO 地址译码及板级访存时序的权威来源。
- `rtl/soc/student_top.sv`：实例化 CPU、双路 IROM 读口和外设桥。
- `rtl/top/top.sv`：板级顶层，包含 PLL、UART、twin controller 和 `student_top`。
- `sim_cpu_only/`：不依赖 Vivado IP 的 CPU-only Verilator/Icarus 仿真环境。
- `rt-thread/`：RT-Thread Nano 3.1.5 移植（vendor 内核 + `bsp/mycpu`），演示经 LED 完成值在 Verilator 仿真中验收。
- `tb/`：Vivado CPU、板级和 UART testbench。
- `vivado/tests/`：分层汇编测试、链接脚本和镜像生成工具。
- `ip/`、`constraints/`：Vivado IP 配置和板级约束。

## 当前微架构

### 流水线与双发射

- 对外仍按 `IF -> ID -> EX -> MEM -> WB` 模块组织，实际流水边界为 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`。
- 每拍最多顺序发射两条指令。第一槽沿用 `IF_`、`ID_`、`EX_`、`MEM_`、 `MEM2_`、`WB_` 前缀，第二槽使用 `_S1` 后缀。
- 第二槽只在包内无 RAW 依赖且资源允许时有效。控制流、CSR、双访存、双 RV32M 等组合会退化为单发射；提交顺序始终是第一槽先于第二槽。
- 流水有效性由 valid 信号和副作用控制共同约束。reset、flush 或气泡必须保证寄存器写、存储器写、CSR 写和重定向均无副作用。
- 任一槽的 RV32M 单元忙时，前端和 ID/EX 保持。普通 `MUL` 使用一个等待周期，高位乘法使用两个等待周期，普通除法/余数使用 32 次迭代；除零和有符号溢出按 RISC-V 语义单独处理。

### 取指与控制流

- CPU 复位入口为 `32'h8000_0000`。
- `student_top.sv` 使用 `pc[15:2]` 和相邻字地址访问 64 KiB 双路 IROM，高位 PC 被有意忽略；IF 的双发射提示表与 BTB tag 必须覆盖 `pc[15:8]`，避免跨 16 KiB 地址别名。
- IF 内含直接映射的双发射提示表。冷启动或 tag 未命中时先单发射，再根据同步 IROM 返回的两条指令训练对应表项。
- 条件分支预测使用 64 项 2 位饱和计数 BHT；未训练条件分支采用 BTFNT。 `jal` 在 IF 预测跳转，`jalr`、异常入口和 `mret` 由 EX 解析。
- EX 比较实际结果和预测结果。预测错误时重定向 PC，并冲刷 IF/ID 与 ID/EX；预测正确时不冲刷流水线。

### 冒险、前递与寄存器堆

- `hazard_unit.sv` 同时检查两个消费者槽对 ID/EX 和 EX/MEM1 两槽 load 的依赖，并分别统计 EX、MEM 阶段造成的 load-use 停顿。
- `forwarding_unit.sv` 为两个 EX 槽直接选择前递数据。阶段优先级为较新的 MEM1 高于 MEM2，高于 WB；同一阶段内第二槽结果比第一槽更新。
- `reg_file.sv` 提供两路写回和两组读端口，包含 WB 到 ID 的同周期旁路，屏蔽对 `x0` 的写入。实例名 `rf_inst` 受 testbench 层次引用约束。
- 非普通 ALU 写回值必须在各阶段统一形成可前递数据，不能只更新最终 WB mux。

### Load/store 与 L0

- CPU 对外只有一组数据访问接口，因此同拍最多发射一条访存指令。
- BRAM 为同步读取。load 请求经 MEM1/MEM2 返回，完整 32 位原始字进入后端， byte/half 选择及符号扩展在写回路径完成；MMIO 读取保持独立的数据时序。
- `load_l0_cache.sv` 是 64 项直接映射的 BRAM load 结果缓存，缓存完整 32 位字。 EX 提前探测命中后，可让紧随其后的依赖指令从 MEM1 获得数据。
- L0 仅覆盖 BRAM 地址，不缓存 MMIO。store 仍写穿到 BRAM，并失效同一字地址的缓存行。
- 字节、半字访问由 `mycpu_lsu.sv`、`load_mask.sv`、`bram_driver.sv` 和 CPU 后端共同完成，修改时必须保持地址低位、mask、拼接和符号扩展一致。

## 地址映射

当前行为以 `rtl/bus/perip_bridge.sv` 为准：

- BRAM：`0x8010_0000`—`0x8013_FFFF`
- SW0：`0x8020_0000`
- SW1：`0x8020_0004`
- KEY：`0x8020_0010`
- SEG：`0x8020_0020`
- LED：`0x8020_0040`
- COUNTER：`0x8020_0050`

COUNTER 写入 `0x8000_0000` 开始计数，写入 `0xFFFF_FFFF` 停止计数。链接脚本、汇编注释或旧测试若与 RTL 不一致，先按 `perip_bridge.sv` 核对实际行为。

## 接口与编码约定

- `rtl/core/mycpu.sv` 的端口列表是固定接口：不得增删、改名、改宽度、改方向，也不得改变双路 IROM 与数据总线的时序语义。
- 延续现有 SystemVerilog 风格，优先使用 `logic`、`always_comb`、`always_ff`。
- 保持双槽命名、流水级前缀和 testbench 依赖的实例层次稳定。
- 保持现有 ALU 一热控制编码。新增或调整运算时，同步核对 `defines.sv`、 `alu_ctrl.sv`、译码器、流水寄存器和 RV32M 单元。
- 中文源码和文档保持 UTF-8；新增注释只说明设计意图、接口时序或易错约束。
- 未明确要求 SoC、外设、板级、测试或 IP 变更时，CPU 功能修改仅限 `mycpu` 所属模块。不要通过修改 `student_top.sv`、`top.sv`、 `perip_bridge.sv`、testbench 或 IP 来掩盖核心问题。
- 不编辑 Vivado 生成目录、`.runs`、`.cache`、`.sim` 或日志。`.xci` 仅在任务明确要求修改 Vivado IP 时变更。

## 测试镜像

`vivado/tests/Makefile` 当前以 `-march=rv32im -mabi=ilp32` 编译四个 tier 的汇编测试，并生成 `.elf`、`.bin`、`.coe`、`.mif` 和反汇编文件：

```sh
cd vivado/tests
make
make t10_fibonacci
make t18_m_ext_basic
make t19_zicsr_trap
make clean
```

Makefile 会依次尝试 `riscv32-unknown-elf-`、`riscv-none-embed-` 和 `riscv64-unknown-elf-` 工具链前缀。生成物位于 `vivado/tests/build/`。

测试分层如下：

- `tier1_basic/`：RV32I 基础、load/store、CSR/外设、RV32M、Zicsr/陷阱。
- `tier2_hazard/`：前递、load-use 和分支冒险。
- `tier3_perf/`：算法性能负载。
- `tier4_bench/`：综合 benchmark。

## CPU-only 仿真

`sim_cpu_only/` 使用行为 IROM、BRAM 和 MMIO 模型直接编译 CPU RTL，不依赖 Vivado 工程。常用命令：

```sh
./sim_cpu_only/run_verilator.sh
./sim_cpu_only/run_regression.sh
./sim_cpu_only/run_regression_t05_t08.sh
```

也可在目录内覆盖镜像和完成值：

```sh
cd sim_cpu_only
make sim-verilator \
  IROM_COE=../vivado/tests/build/t10_fibonacci.coe \
  PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE
```

- 输入支持 `.coe`、`.mif` 和逐行 32 位 word 的 `.mem`。
- 默认配置位于 `sim_cpu_only/config.mk`，包括镜像、LED 完成值、时限、频率、波形和日志详细度。
- testbench 可按 LED 完成值、仿真时限或 `$finish` 结束。通用汇编测试使用 `0xC0DEC0DE` 表示通过、`0xDEADBEEF` 表示失败；默认竞赛镜像可在 `config.mk` 中使用另一组完成值。
- 性能输出包括周期、写回、双发射包、前端停顿、load-use EX/MEM 停顿、 RV32M busy、L0 命中、退休指令、CPI 和 MIPS。统计信号依赖 `uut`/`Core_cpu` 下的内部层次，相关信号改名时必须同步维护 testbench。

## Vivado 验证

- `tb/tb_myCPU.sv`：CPU 功能和性能仿真，等待 LED 写入 `32'hC0DEC0DE` 或 `32'hDEADBEEF` 后结束并打印统计。
- `tb/tb_top.sv`：板级 UART/twin-controller 集成行为。
- `tb/tb_uart.sv`：UART 独立行为。
- 综合和实现结果以当前 Vivado run 的 utilization、timing summary 和 route status 报告为准。不要把 `.runs` 内生成报告或 bitstream 直接当作 RTL 源文件编辑。

## 修改时的一致性检查

- 改指令译码：同步检查 `defines.sv`、`main_ctrl.sv`、`alu_ctrl.sv`、 `imm_gen.sv`、`mycpu_decoder.sv`、CSR 控制和相关汇编测试。
- 改写回来源：同步检查 `MemToReg` 编码、五组流水寄存器、MEM1/MEM2 前递数据和 WB mux，两槽定义必须一致。
- 改冒险或前递：至少覆盖 `t07_forwarding`、`t08_load_use`、 `t09_branch_hazard`，并检查两槽生产者/消费者组合。
- 改分支、跳转、CSR 或陷阱：同步检查预测元数据、EX 重定向、valid、 IF/ID 与 ID/EX 冲刷以及 `t19_zicsr_trap`。
- 改 load/store：同步检查 LSU、L0、load mask、BRAM driver、MEM1/MEM2、 MMIO 时序和地址译码。
- 改双发射判定：保持 IF 提示表训练、ID 第二槽有效性、包内依赖、单访存、单 RV32M 和顺序提交约束一致。
- 改顶层或时钟复位：保持 `top.sv`、`student_top.sv`、约束、testbench 和 Vivado IP 的时钟、复位极性及 IROM/BRAM 延迟一致。

### CPU 频率调整（PLL、IROM、BRAM）

修改板级 CPU 时钟频率时，必须在同一变更中同步核对以下项目；外设时钟（当前为 50 MHz）若不变，不要误改：

1. **PLL IP 与生成脚本**
   - `ip/pll/pll.xci`：用户参数 `CLKOUT2_REQUESTED_OUT_FREQ`，以及对应的 `C_CLKOUT2_*`、`C_OUTCLK_SUM_ROW2`、`C_CLKOUT1_ACTUAL_FREQ` 和端口 `FREQ_HZ` 等生成字段。
   - `scripts/create_project.tcl`、`scripts/recreate_pll_ip.tcl`、`scripts/recreate_irom_ip.tcl`、`scripts/recreate_bram_ip.tcl`：PLL 频率、IROM/BRAM 端口时钟和初始化 COE 路径必须与 XCI 一致。
2. **IROM/BRAM IP 时钟**
   - `ip/IROM/IROM.xci`：`Port_A_Clock`、`Port_B_Clock`。
   - `ip/BRAM/BRAM.xci`：`Port_A_Clock`、`Port_B_Clock` 和关联端口 `FREQ_HZ`。
   - `scripts/create_project.tcl`、`scripts/recreate_irom_ip.tcl`、`scripts/recreate_bram_ip.tcl`：IROM/BRAM 的 `CONFIG.Coe_File`、`CONFIG.Port_A_Clock`、`CONFIG.Port_B_Clock`；同时保持 IROM 深度与当前 `student_top.sv` 地址位宽、链接脚本和 COE 生成上限一致。
3. **时钟消费者与验证配置**
   - `rtl/top/top.sv`、`rtl/bus/perip_bridge.sv`、`rtl/peripheral/uart_bridge.sv`：时钟域注释和跨域说明。
   - `tb/tb_myCPU.sv`：CPU 时钟统计参数 `CPU_CLK_MHZ`。
   - `sim_cpu_only/Makefile`、`sim_cpu_only/config.mk`、`sim_cpu_only/sim_config_gen.py`、`verification/tools/run_competition.py`：CPU-only 频率与周期/MIPS 换算默认值。
   - 当前设计频率变更后，更新 `docs/cpu_capability_boundaries.md`、`docs/tests/cpu_test_plan.md` 和 `rt-thread/README.md` 中的现行频率说明；历史测试报告中的实测值不得伪造改写。
4. **检查与生成**
   - 用搜索确认上述源文件不残留旧 CPU 频率字段；对三个 `.xci` 执行 JSON 解析检查。
   - Vivado IP 变更后重新生成 output products，并以综合/实现时序报告确认目标频率；禁止直接编辑 `.runs`、`.cache`、`.gen` 或 `.sim` 生成物。
   - 频率只改变时，IROM/BRAM 初始化 COE 内容通常无需改写；只有镜像内容变化时才重新生成对应 COE。

## Git 约定

- 工作区可能包含用户尚未提交的修改；不要覆盖、回退或顺带整理无关文件。
- 分支默认使用 `codex/` 前缀。
- Commit message 使用 Conventional Commits：`type(scope): 中文摘要`。
- 常用类型为 `feat`、`fix`、`refactor`、`docs`、`style`、`chore`；摘要使用简短中文动宾短语，不以句号结尾。
- 示例：`docs: 更新 CPU 工程协作说明`、 `fix(cpu): 修正双槽 load-use 冒险判断`。

## 已知注意事项

- PowerShell 读取中文文件时显式使用 UTF-8，避免误判源码乱码。
- Verilator 不支持在过程块的 `for` 循环中对大数组元素使用延迟（非阻塞）赋值进行复位，可能报 `BLKLOOPINIT`；此类复位循环应沿用当前已验证的阻塞赋值写法，并保证综合语义不变。
- Git 可能报告 dubious ownership；除非 Git 操作确实需要且获得授权，不修改用户的全局 Git 配置。
- 同步 IROM 和同步 BRAM 的返回拍数是核心接口语义，行为模型与 Vivado IP 必须保持一致。
- 程序完成值必须匹配所用 testbench/config；否则可能出现程序已结束但仿真继续运行至超时的假失败。
- `vivado/tests/build/` 中可能存在历史生成物。判断测试源码和编译参数时，以 tier 目录、Makefile 和本次重新生成的文件为准。
