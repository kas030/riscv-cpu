# RT-Thread CoreMark 10000 次性能优化

本目录用于优化当前 CPU 在 RT-Thread Nano 上运行官方 CoreMark 1.0
`2K performance` 负载 10000 次的时间。固定命令为：

```text
coremark 0 0 0x66 10000
```

日常迭代默认仿真 16 次，并在同一次运行的第 8、16 次迭代抓取统计，外推
10000 次结果。这样保留 RT-Thread 启动、FinSH 命令、CoreMark 初始化、完整算法、
CRC 校验和返回 shell 的真实路径，同时把开发仿真从约 23 秒目标运行缩短到约
0.04 秒仿真时间。

为进一步减少仿真固定开销，性能固件会启用 `COREMARK_PERF_AUTORUN`：调度器启动
后由一个 RT-Thread 线程用与上述命令完全相同的 `argc/argv` 调用 msh 导出的
`coremark` 移植入口，运行结束后仍由 FinSH 输出 `msh >`。该开关默认关闭，不改变
正常 RT-Thread 固件；它省去了仿真 UART 单字节接收和 shell 文本解析，不省略
CoreMark 的初始化、计时、算法、CRC 或报告路径。

`COREMARK_PERF` 仿真还会直接捕获 CPU 对 UART DATA MMIO 的写入，并在字节流中
校验参数、迭代数、三项 CRC、十秒规则和最终 shell 提示符。因为 CoreMark
timed section 内不输出字符，这不改变被测算法周期。COUNTER 在此模式下由
CPU 周期按当前 `CPU_FREQ_MHZ` 等价分频，避免额外的 50 MHz 时钟事件；普通
CPU-only 模式仍使用真实 UART/twin/bridge 和独立 COUNTER 时钟。

## 使用

在仓库根目录运行：

```sh
./coremark-perf/run_coremark_verilator.sh estimate --tag baseline
./coremark-perf/run_coremark_verilator.sh quick --tag opt01-check
./coremark-perf/run_coremark_verilator.sh stage --tag opt01-stage
./coremark-perf/run_coremark_verilator.sh full --tag opt01-full
```

模式含义：

| 模式 | 实跑次数 | 观察点 | 用途 |
|---|---:|---:|---|
| `estimate` | 16 | 8 / 16 | 日常优化与 10000 次外推 |
| `quick` | 1 | 1 | 最短 CRC/路径检查，不生成外推报告 |
| `stage` | 64 | 32 / 64 | 更低计时量化误差的阶段检查 |
| `full` | 10000 | 5000 / 10000 | 正式有效运行和最终验收 |

可向 CPU-only Makefile 传参，例如：

```sh
./coremark-perf/run_coremark_verilator.sh estimate --tag opt02 \
  STOP_NS=500000000 PROGRESS_NS=50000000 CPU_FREQ_MHZ=200.0
```

工具链默认依次寻找 `riscv32-unknown-elf-` 和 `riscv64-unknown-elf-`。也可设置：

```sh
CROSS=/opt/riscv/bin/riscv32-unknown-elf- \
  ./coremark-perf/run_coremark_verilator.sh estimate --tag baseline
```

结果写入 `coremark-perf/results/<tag>-<mode>/`，包括固件、反汇编、仿真日志、
RTL/移植层/固件哈希以及 JSON/Markdown 指标。`run.meta` 还会逐项记录各
CoreMark 源文件实际采用的编译参数。`results/` 默认不提交。

## 外推方法

testbench 从本次构建的 ELF 自动读取 `core_bench_list` 地址，不固定依赖某个 PC。
它在该入口指令由 WB 唯一退休时计数，不会把 EX 停顿期间保持的 valid/PC 重复
计算。每个 CoreMark 迭代调用该函数两次；第二次入口作为观察点。任意两个同类
观察点的差值严格覆盖整数个完整迭代，因此：

```text
每次增量 = (snapshot16 - snapshot8) / 8
metric10000 = final16 + (10000 - 16) × 每次增量
```

`metric10000` 保留启动 RT-Thread、调度 autorun 线程、初始化和结果输出等固定开销。
报告还会用 `cycles/iteration` 单独计算稳态 10000 次时间与
`iterations/second`，避免 COUNTER 的 1 ms 量化误差。分析器同时解析 CoreMark
自己的 `Total ticks`，将观察点估算的 16 次耗时与它交叉校验；两者超出计时器
量化和少量边界指令所允许的误差时直接拒绝生成报告。`stage` 的 64 次样本还会
把 1 ms 计时量化对应的 10000 次外推不确定度降到约 ±0.16 秒。

短测会正常打印官方的“运行不足 10 秒”错误，因此不是可发布的 CoreMark 成绩；
它必须同时满足以下条件才可用于外推：

- 固定 performance seeds、2K 数据规模及命令中的实际迭代次数全部回显正确；
- CRC 为 `crclist=e714`、`crcmatrix=1fd7`、`crcstate=8e3a`；
- 不出现任何算法 CRC 错误，并返回 `msh >`；
- 8/16 两个观察点和最终 CPU 统计来自同一次运行，且与 `Total ticks` 一致。

`full` 还必须执行 10000 次、运行至少 10 秒、输出
`Correct operation validated`，并且不出现 `Errors detected`。

## 修改边界

允许修改：

- 移植接口：`core_portme.c`、`core_portme.h`、`coremark_cmd.c`、BSP 的条件式
  autorun 接口及相关构建参数；
- CPU、存储层和其他硬件 RTL，包括针对固定负载的硬件加速；
- 本目录和 CPU-only 验证设施。

禁止修改：

- `core_list_join.c`、`core_matrix.c`、`core_state.c`、`core_util.c`；
- `core_main.c`、`coremark.h` 中现有基准执行与校验逻辑；
- CRC 期望值、迭代次数回显或正式有效性判定。

上述受保护文件由 [protected_sources.sha256](protected_sources.sha256) 固定。每次
构建前后都会校验，任何差异都会使脚本失败。上游四个算法文件还可用
`rt-thread/bsp/mycpu/coremark/coremark.md5` 交叉核对。

更完整的优化、阶段回归和 Vivado 复核约定见
[COREMARK_OPTIMIZATION_WORKFLOW.md](COREMARK_OPTIMIZATION_WORKFLOW.md)。
