# CPU-only Simulation

这里是轻量级 CPU-only Verilator 仿真流程。它用 `tb_cpu_only.sv` 中的行为模型替代
Vivado IROM/BRAM IP 和板级外设，便于快速验证 CPU 核。

常用输入在 `config.mk` 中配置：

```make
IROM_COE := ../sim/coe/mext/irom-v2.coe
BRAM_COE := ../sim/coe/mext/dram.coe
EXPECTED_LED :=
PASS_LED := 078B7323
FAIL_LED := 24181824
TRACE := 0
STOP_NS := 400000000
PROGRESS_NS := 10000000
QUIET := 1
```

注意：

- 首次在新机器上运行时，先安装 `python3`、`make`、`verilator`、C++ 工具链。
  默认从 `PATH` 查找工具；如果工具不在 `PATH`，可以在命令行覆盖：
  `make VERILATOR=/path/to/verilator CXX=/path/to/g++ sim-verilator`。
- 本流程直接编译 `rtl/` 下的 CPU 核心模块，不依赖 Vivado 工程。
- MMIO FPU 可脱离 CPU 和 CoreMark 单独验证；在 `sim_cpu_only` 目录运行
  `make test-fpu-mmio`。测试直接驱动寄存器协议，检查整数转单精度、除法、舍入、
  符号、零值和 CoreMark 计时换算向量，日志写入
  `build/fpu-mmio-test.log`。
- IROM/BRAM 输入支持 Vivado `.coe`、Quartus-style `.mif`，以及每行一个
  32 位 hex/binary word 的 `.mem` 文本。
- 默认竞赛镜像判定值为 `PASS_LED=078B7323`、`FAIL_LED=24181824`。程序写入
  其中任意一个值都会触发 `stop_reason: led` 并结束仿真；`EXPECTED_LED`
  非空时会额外要求最终 LED 精确等于该值。
- 降噪参数由 `QUIET` 控制。`QUIET=1` 时，Makefile 会自动探测当前
  Verilator 支持的 `--quiet`、`--quiet-build`、`--quiet-exit` 并只启用可用项；
  同时始终使用 `-MAKEFLAGS -s` 降低内部 make 输出。
- Ubuntu/Debian 的 Verilator 5.020 包不支持 `--quiet`、`--quiet-build` 和
  `+verilator+quiet`。如果需要完整使用这些降噪参数，建议安装更新的上游
  Verilator，或从源码构建后通过命令行指定：

```sh
make sim-verilator \
  VERILATOR=/path/to/new/verilator \
  CXX=/path/to/g++ \
  VERILATOR_RUNTIME_ARGS=+verilator+quiet
```

  若新版本仍不支持运行时 `+verilator+quiet`，保持 `VERILATOR_RUNTIME_ARGS`
  为空即可；编译期降噪会继续按能力探测自动启用。
- 正确性、RV32M、流水线和存储测试统一由独立验证目录构建：

```sh
cd verification
make check
make regression
```

在仓库根目录运行：

```sh
./sim_cpu_only/run_verilator.sh
```

运行可信开源白名单或竞赛镜像：

```sh
cd verification
make run-open-source
make competition
```

也可以直接进入目录运行：

```sh
cd verification
make run TEST=rv32i
```
