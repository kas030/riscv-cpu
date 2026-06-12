# 仿真使用说明

本文说明如何使用本仓库的 CPU-only Verilator 仿真流程。该流程不依赖 Vivado，不仿 PLL、UART、数码管扫描等板级外设，主要用于快速验证 CPU 核、IROM/BRAM 初始化和 MMIO 输出。

## 1. 整体流程

一次仿真大致分为 4 步：

1. 在 `sim_cpu_only/config.mk` 中选择 IROM/BRAM 的 `.coe` 文件和可选 LED 期望值。
2. 运行 `./sim_cpu_only/run_verilator.sh`。
3. 脚本将 `.coe` 转换为 `sim_cpu_only/build/*.mem`。
4. Verilator 编译并运行 `tb_cpu_only.sv`，日志写入 `sim_cpu_only/build/verilator-sim.log`。

## 2. 配置仿真输入

常用配置写在：

```text
sim_cpu_only/config.mk
```

示例：

```make
IROM_COE := ../digital_twin.srcs/sources_1/imports/test_src/irom.coe
BRAM_COE := ../digital_twin.srcs/sources_1/imports/test_src/bram.coe
EXPECTED_LED := 01221c08
TRACE := 0
CPU_FREQ_MHZ := 150.0
STOP_NS := 400000000
PROGRESS_NS := 10000000
```

路径相对于 `sim_cpu_only/` 解析，因为脚本会进入该目录运行 `make`。`EXPECTED_LED` 留空时不检查 LED，只打印当前 LED 值：

```make
EXPECTED_LED :=
```

`STOP_NS` 是仿真停止时间，单位是 ns。`400000000` 表示 400 ms。

`CPU_FREQ_MHZ` 是 CPU-only testbench 直接生成的 CPU 主频，单位 MHz。默认 `150.0`，即 CPU 时钟周期约 `6.667 ns`。这个流程不实例化 Vivado PLL，因此修改该值会改变 `tb_cpu_only.sv` 里驱动 `mycpu.cpu_clk` 的仿真时钟。

`PROGRESS_NS` 是终端进度打印间隔，单位也是 ns。`10000000` 表示每 10 ms 仿真时间打印一次进度；设为 `0` 则关闭周期性进度输出。仿真结束时进度行会被清空，不会留在最终报告前。

`TRACE := 1` 会打开 FST 波形输出，默认文件为 `sim_cpu_only/build/wave.fst`。平时建议保持 `TRACE := 0`，因为波形会降低仿真速度并占用更多磁盘空间。打开 trace 时建议把 `STOP_NS` 改小，例如 `1000000` 只抓前 1 ms。

如需切换输入或检查条件，直接修改 `sim_cpu_only/config.mk`，然后重新运行脚本。当前流程使用编译期配置，运行时不再通过命令行 plusargs 覆盖这些参数。

## 3. 运行仿真

首次在一台新机器上运行本仓库时，建议先做这几步：

1. 安装基本依赖：`python3`、`verilator`、C++ 编译器；如需 `sim-iverilog`，再安装 `iverilog` / `vvp`。
2. 检查并按本机环境修改这些变量：
   `sim_cpu_only/run_verilator.sh` 中的 `ENV_BIN`；
   `sim_cpu_only/Makefile` 中的 `MAMBA`、`MAMBA_ROOT`、`ENV`。
3. 回到仓库根目录运行 `./sim_cpu_only/run_verilator.sh`。

在仓库根目录运行：

```sh
./sim_cpu_only/run_verilator.sh
```

修改已有 CPU RTL 或 `sim_cpu_only/config.mk` 后，仍然直接运行这条命令即可。`make` 会根据文件时间戳自动重新编译受影响的 RTL 和配置头文件，不需要手动 clean。

运行过程中，终端会周期性输出类似信息：

```text
[progress] sim=10000000ns / 400000000ns (2.5%)
```

如果怀疑缓存异常，或想强制全量重编译：

```sh
cd sim_cpu_only
/home/mph/.local/micromamba/envs/hdl/bin/make clean
cd ..
./sim_cpu_only/run_verilator.sh
```

## 4. 查看仿真结果

日志文件：

```text
sim_cpu_only/build/verilator-sim.log
```

成功示例：

```text
>>> [PASS] final state matches enabled checks
virtual_led       : 0x01221c08
led_graphic       :
                    .......#
                    ..#...#.
                    ...###..
                    ....#...
seg_wdata         : 0x37000309
cnt_ms            : 309
CPI (approx)      : 1.970
```

`seg_wdata` 不是固定期望值，日志只打印当前值。counter 在程序写 counter-start MMIO 后才开始计时，所以 400 ms 检查点不一定显示 `0400`。

## 5. 添加或修改 RTL

修改已有 CPU 文件后直接重新运行脚本即可。

如果新增了 CPU RTL 文件，例如：

```text
digital_twin.srcs/sources_1/imports/new/NewUnit.sv
```

需要把它加入 `sim_cpu_only/Makefile` 的 `CPU_SRCS` 列表。当前流程不会自动扫描全部 `.sv` 文件，目的是保持编译顺序稳定、可控。

## 6. 查看新信号与波形

临时调试推荐在 `sim_cpu_only/tb_cpu_only.sv` 中加 `$display`，例如：

```systemverilog
$display("pc=0x%08X alu=0x%08X", irom_addr, dut.EX_alu_result);
```

如果需要完整波形，将 `sim_cpu_only/config.mk` 中的 `TRACE` 改为 1：

```make
TRACE := 1
STOP_NS := 1000000
```

然后运行：

```sh
./sim_cpu_only/run_verilator.sh
```

生成的波形文件为：

```text
sim_cpu_only/build/wave.fst
```

可用 GTKWave 打开：

```sh
gtkwave sim_cpu_only/build/wave.fst
```

如果本机没有 GTKWave，可以先保留 `.fst` 文件，拷到有 GTKWave 的环境查看。

不要一开始就对 400 ms 全程开 trace，波形可能达到数百 MB 甚至更大。先用较小 `STOP_NS` 定位问题，再按需放大窗口。短窗口通常还没运行到最终 LED，因此建议在 `config.mk` 中临时清空 `EXPECTED_LED`，关闭最终 LED 期望值检查。

## 7. CPI 统计口径

日志中的 CPI 是近似值：

```text
CPI = cycles / approx_inst
approx_inst = writeback(RF) + stores + taken branches
```

`cycles` 是 CPU 时钟周期数。`writeback(RF)` 统计写回寄存器且目标不是 `x0` 的指令，`stores` 统计写 MMIO/BRAM 的 store，`taken branches` 统计实际跳转或 taken 分支。该口径适合观察性能趋势，但不是严格 retire 计数。

## 8. 何时使用 Vivado

CPU-only 仿真不替代完整 Vivado 仿真。需要验证以下内容时，应打开 `digital_twin.xpr` 使用 Vivado/xsim：

- Xilinx IROM/BRAM IP 配置和初始化；
- PLL、UART、数码管扫描等板级外设；
- 综合后功能仿真或实现相关问题。

## 9. M 扩展测试经验记录

本仓库已经补充了一份 RV32M 基础自检程序：

```text
tests/tier1_basic/t18_m_ext_basic.S
```

它覆盖：

- `mul / mulh / mulhsu / mulhu`
- `div / divu / rem / remu`
- 除数为 0 的标准特殊情况
- `0x80000000 / -1` 的有符号溢出特殊情况

### 9.1 `run_verilator.sh` 与 `tests/Makefile` 的分工

`./sim_cpu_only/run_verilator.sh` 只负责读取现成的 `IROM_COE` / `BRAM_COE`，转换成 `build/*.mem` 后运行 Verilator。它本身不关心测试镜像最初是按 `rv32i` 还是 `rv32im` 编出来的。

真正会限制指令集的是：

```text
tests/Makefile
```

如果要从 `tests/tier*/` 下的汇编源码重新生成镜像，编译选项必须允许 M 扩展。当前仓库已将：

```make
-march=rv32i
```

改成：

```make
-march=rv32im
```

否则汇编器会拒绝 `mul/div/rem` 等指令。

### 9.2 CPU-only 仿真判定 PASS 的方式

`sim_cpu_only/tb_cpu_only.sv` 监听的是 MMIO LED 地址：

```text
0x8020_0040
```

因此测试程序最终应把 `0xC0DEC0DE` 或 `0xDEADBEEF` 写到 LED 地址，而不是只写到旧 testbench 使用的其他“结果地址”。

一个常用收尾模板是：

```asm
pass:
    li      a0, 0xC0DEC0DE
    j       done
fail:
    li      a0, 0xDEADBEEF
done:
    lui     t0, 0x80200
    addi    t0, t0, 0x40
    sw      a0, 0(t0)
1:  j       1b
```

另外，当前 CPU-only testbench 不会在 LED 命中后立刻停机，而是等到 `STOP_NS` 后统一打印最终状态并做 `EXPECTED_LED` 检查。所以对这类快速自检程序，建议把 `STOP_NS` 设小一些，例如：

```sh
./sim_cpu_only/run_verilator.sh EXPECTED_LED=C0DEC0DE STOP_NS=20000 PROGRESS_NS=0
```

这样既能验证最终 LED，又不会白等很久。

### 9.3 没有 RISC-V 交叉编译器时的替代方案

如果本机缺少：

- `riscv32-unknown-elf-gcc`
- `riscv-none-embed-gcc`
- `riscv64-unknown-elf-gcc`

就无法通过 `tests/Makefile` 直接把 `.S` 编成新的 `irom.coe`。这种情况下，不必为了一个小测试临时安装整套工具链，也不建议为了任务本身去“现写一个通用编译器”。

当前仓库已经提供了一个更轻量的兜底脚本：

```text
tests/tools/gen_t18_m_ext_basic_coe.py
```

它直接生成 `t18_m_ext_basic` 对应的 RV32IM 指令镜像，不依赖外部 RISC-V 工具链：

```sh
python3 tests/tools/gen_t18_m_ext_basic_coe.py tests/build/t18_m_ext_basic.coe
```

然后可直接覆盖 `IROM_COE` 跑 CPU-only 仿真：

```sh
./sim_cpu_only/run_verilator.sh \
  IROM_COE=../tests/build/t18_m_ext_basic.coe \
  EXPECTED_LED=C0DEC0DE \
  STOP_NS=20000 \
  PROGRESS_NS=0
```

这条路径适合“先快速验证某个小功能是否通了”，尤其适合当前这类基础 M 扩展冒烟测试。
