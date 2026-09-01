<div align="center">
  <h1>基于 RISC-V 指令集的 CPU 设计</h1>
  <h3>第十届集创赛——“竞业达”企业命题</h3>
</div>

本项目面向竞业达 FPGA 数字孪生平台，使用 SystemVerilog 设计并实现了一套 32 位小端 RISC-V 处理器及配套 SoC。CPU 支持 RV32I、RV32M 和项目运行时所需的 Zicsr/机器模式陷阱返回功能，采用双槽顺序发射、顺序提交结构，并可运行裸机程序、RT-Thread Nano 3.1.5 和 EEMBC CoreMark 1.0。

项目同时提供 CPU-only 仿真、分层指令测试、开源指令用例、Vivado 工程重建与 bitstream 构建脚本，覆盖从 RTL 功能验证到 FPGA 板级运行的完整流程。

## 关键分支

| 分支 | 说明 |
| --- | --- |
| `main` | 最终全国总决赛版本 |
| `regional` | 分区赛决赛版本 |

不同比赛阶段的 RTL、软件镜像和验证配置可能存在差异。复现某一版本时，请保持分支内的源码、IP 配置、初始化镜像和测试脚本配套使用。

## 项目亮点

- **双槽顺序流水线**：每拍最多顺序发射和提交两条指令，实际流水边界为 `IF/ID -> ID/EX -> EX/MEM1 -> MEM1/MEM2 -> MEM2/WB`。
- **RV32IM 执行能力**：覆盖 37 条 RV32I 基础指令和 RV32M 全部 8 条指令，乘除法由多周期执行单元完成。
- **运行时支持**：实现六种 Zicsr 指令以及项目所需的 `ecall`、`mret` 和最小 M-mode trap 通路，可运行 RT-Thread Nano。
- **控制流优化**：前端集成双发射提示表、BHT/BTB 分支预测以及 EX 级统一重定向。
- **数据相关优化**：提供双槽冒险检测、多级前递、WB-to-ID 同周期旁路、load-use 控制和 store bypass。
- **存储优化**：使用 MEM1/MEM2 两级后端适配同步 BRAM，并实现 64 项直接映射 L0 load cache。
- **软硬件协同**：集成 UART、计时器、MMIO FPU、I²C/BME280、LED、数码管等外设，提供 finsh/msh 命令行、CoreMark 和传感器演示。
- **完整验证链路**：支持 Verilator CPU-only 快速仿真、Vivado/XSim 行为仿真、定向回归、固定版本开源指令测试和板级验证。

> [!NOTE]
> 当前能力为 **RV32IM + 最小 Zicsr/M-mode trap 子集**，并非完整的 RISC-V 特权架构实现。详细边界见 [CPU 能力边界](docs/cpu_capability_boundaries.md)。

## 系统架构

![CPU SoC 总体结构](docs/assets/cpu-soc-overview.png)

系统由 CPU 核、双路同步 IROM、数据 BRAM、外设桥和 RT-Thread BSP 组成。CPU 复位入口为 `0x8000_0000`，两路 IROM 端口并行读取当前 PC 和 `PC + 4`；数据侧通过统一接口访问 BRAM 或 MMIO 外设。

![CPU 双槽流水微架构](docs/assets/cpu-core-microarchitecture.png)

槽 0 保存包内较老指令，槽 1 保存较年轻指令。两槽共享访存和多周期执行资源，当包内存在 RAW 相关、双访存、双 RV32M 或其他资源冲突时，处理器自动退化为单发射，以保持顺序执行语义。

### 主要规格

| 项目 | 当前 `main` 配置 |
| --- | --- |
| ISA | RV32I、RV32M、最小 Zicsr/M-mode trap 子集 |
| 数据宽度 | 32 位，小端 |
| 发射/提交 | 双槽、顺序发射、顺序提交 |
| 流水线 | IF、ID、EX、MEM1、MEM2、WB |
| 目标器件 | Xilinx Kintex-7 XC7K325T-FFG900-2 |
| FPGA 工具 | AMD Vivado 2025.2.1 |
| 时钟 | CPU 200 MHz，外设 50 MHz |
| 指令存储器 | 64 KiB 双口同步 IROM |
| 数据存储器 | 256 KiB BRAM |
| 系统软件 | RT-Thread Nano 3.1.5 |
| RTL 语言 | SystemVerilog |

## 目录结构

```text
.
|-- rtl/
|   |-- core/               CPU 核心顶层
|   |-- pipeline/           流水级组合逻辑与级间寄存器
|   |-- control/            译码、立即数、下一 PC 与重定向控制
|   |-- datapath/           ALU、寄存器堆、PC 与 RV32M 单元
|   |-- hazard/             双槽冒险检测与前递
|   |-- memory/             LSU、load mask、BRAM 驱动与 L0 cache
|   |-- bus/                BRAM/MMIO 外设桥
|   |-- soc/                CPU、IROM 与外设桥集成
|   `-- top/                FPGA 板级顶层
|-- sim_cpu_only/           不依赖 Vivado IP 的 Verilator/Icarus 仿真
|-- verification/           当前可信测试、回归与开源用例入口
|-- rt-thread/              RT-Thread Nano 移植、BSP 与演示程序
|-- tb/                     Vivado CPU、板级、UART、I²C testbench
|-- vivado/tests/           分层汇编测试与镜像生成工具
|-- ip/                     PLL、IROM、BRAM 等 Vivado IP 配置
|-- constraints/            FPGA 管脚与时序约束
|-- scripts/                Vivado 工程创建、仿真和构建脚本
`-- docs/                   技术报告、测试报告与架构图
```

核心顶层接口位于 [`rtl/core/mycpu.sv`](rtl/core/mycpu.sv)，SoC 集成入口位于 [`rtl/soc/student_top.sv`](rtl/soc/student_top.sv)，板级顶层位于 [`rtl/top/top.sv`](rtl/top/top.sv)。

## 快速开始

### 1. CPU-only 仿真

该流程使用行为 IROM、BRAM 和 MMIO 模型直接编译 CPU RTL，不依赖 Vivado，适合开发阶段快速验证。环境需要 Python 3、GNU Make、Verilator 和 C++ 编译器。

```sh
./sim_cpu_only/run_verilator.sh
```

默认镜像、完成值、仿真时限、波形和日志级别可在 [`sim_cpu_only/config.mk`](sim_cpu_only/config.mk) 中配置。仿真日志输出到 `sim_cpu_only/build/verilator-sim.log`。需要波形时设置 `TRACE := 1`，生成的 `wave.fst` 可用 GTKWave 打开。

更完整的使用方法见 [CPU-only 仿真说明](sim_cpu_only/README.md) 和 [仿真使用说明](SIMULATION.md)。

### 2. 正确性回归

测试镜像需要支持 `rv32im_zicsr/ilp32` 的 RISC-V GCC 工具链。`verification` 默认使用 `riscv64-unknown-elf-` 前缀，可通过 `CROSS` 覆盖。

```sh
cd verification
make check                  # 构建定向测试并检查测试清单
make run TEST=rv32i         # 运行单项测试
make regression             # 运行全部定向回归
make competition            # 运行竞赛镜像端到端测试
```

获取并运行仓库锁定版本的开源 RV32UI/RV32UM 测试：

```sh
cd verification
make fetch-open-source
make verify-open-source
make run-open-source
```

测试范围和实测记录分别见 [CPU 测试计划](docs/tests/cpu_test_plan.md) 与 [CPU 测试报告](docs/tests/cpu_test_report.md)。

### 3. RT-Thread 固件

```sh
cd rt-thread/bsp/mycpu
make              # 生成 IROM/BRAM 初始化镜像
make run          # 构建并运行完整 CPU-only 演示仿真
make coremark-smoke
```

默认工具链前缀为 `riscv32-unknown-elf-`。串口命令行、CoreMark、BME280 接线与软件配置见 [RT-Thread 移植说明](rt-thread/README.md)。

### 4. Vivado 工程

在仓库根目录执行：

```sh
# 从受版本控制的 RTL、约束和 XCI 重新创建工程
vivado -mode batch -source scripts/create_project.tcl

# 运行 CPU 行为仿真
vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_myCPU

# 综合、实现并生成 bitstream
vivado -mode batch -source scripts/run_build.tcl -tclargs bitstream
```

生成的 bitstream 位于 `vivado/digital_twin.runs/impl_1/top.bit`。如需单独运行综合或实现，可将最后一个参数替换为 `synth` 或 `impl`。更多说明见 [Vivado Tcl 脚本文档](scripts/README.md)。

## 地址空间

| 地址或范围 | 外设/存储器 | 说明 |
| --- | --- | --- |
| `0x8000_0000`—`0x8000_FFFF` | IROM | 64 KiB 程序空间 |
| `0x8010_0000`—`0x8013_FFFF` | BRAM | 256 KiB 数据空间 |
| `0x8020_0000` / `0x8020_0004` | SW0 / SW1 | 虚拟开关 |
| `0x8020_0010` | KEY | 虚拟按键 |
| `0x8020_0020` | SEG | 数码管 |
| `0x8020_0040` | LED | LED 输出 |
| `0x8020_0050` / `0x8020_0054` | COUNTER / COUNTER_US | 毫秒/微秒计时 |
| `0x8020_0060` / `0x8020_0064` | UART DATA / STATUS | UART 数据与状态 |
| `0x8020_0070`—`0x8020_0080` | FPU | CoreMark 换算用 MMIO 单元，不属于 RV32F |
| `0x8020_0084`—`0x8020_0090` | I²C | BME280 寄存器访问 |

外设译码和实际时序以 [`rtl/bus/perip_bridge.sv`](rtl/bus/perip_bridge.sv) 为准。

## 文档索引

- [完整技术报告](docs/technical-report.md)
- [CPU 能力边界](docs/cpu_capability_boundaries.md)
- [CPU 正确性与性能测试计划](docs/tests/cpu_test_plan.md)
- [CPU 测试报告](docs/tests/cpu_test_report.md)
- [CPU-only 仿真说明](sim_cpu_only/README.md)
- [RT-Thread Nano 移植说明](rt-thread/README.md)
- [Vivado Tcl 脚本说明](scripts/README.md)
- [技术报告构建说明](docs/README.md)
