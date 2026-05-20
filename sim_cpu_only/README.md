# CPU-only Simulation

这里是轻量级 CPU-only Verilator 仿真流程。它用 `tb_cpu_only.sv` 中的行为模型替代
Vivado IROM/DRAM IP 和板级外设，便于快速验证 CPU 核。

常用输入在 `config.mk` 中配置：

```make
IROM_COE := ../sim/coe/irom.coe
DRAM_COE := ../sim/coe/dram.coe
EXPECTED_LED :=
TRACE := 0
STOP_NS := 400000000
PROGRESS_NS := 10000000
```

注意：

- 首次在新机器上运行时，先安装 `python3`、`verilator`、C++ 工具链，再检查
  `sim_cpu_only/run_verilator.sh` 中的 `ENV_BIN`，以及 `sim_cpu_only/Makefile`
  中的 `MAMBA`、`MAMBA_ROOT`、`ENV` 是否匹配本机环境。
- 本流程直接编译 `rtl/` 下的 CPU 核心模块，不依赖 Vivado 工程。
- 如果要验证新增的 RV32M 基础测试，可以先生成镜像：

```sh
python3 vivado/tests/tools/gen_t18_m_ext_basic_coe.py vivado/tests/build/t18_m_ext_basic.coe
./sim_cpu_only/run_verilator.sh \
  IROM_COE=../vivado/tests/build/t18_m_ext_basic.coe \
  DRAM_COE=../sim/coe/dram.coe \
  EXPECTED_LED=C0DEC0DE \
  STOP_NS=20000000 \
  PROGRESS_NS=1000000
```

在仓库根目录运行：

```sh
./sim_cpu_only/run_verilator.sh
```
