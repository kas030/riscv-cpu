# CoreMark CPU 性能优化流程

## 1. 固定口径

- 系统：仓库当前 RT-Thread Nano 3.1.5 移植；
- 负载：EEMBC CoreMark 1.0，`TOTAL_DATA_SIZE=2000`，单 context；
- 参数：`seed1=0`、`seed2=0`、`seed3=0x66`；
- 目标：10000 iterations；
- 验收 CRC：`e714 / 1fd7 / 8e3a`；
- 默认仿真 CPU 频率：200 MHz。

优化比较必须保持上述口径不变。可以优化移植接口和任意硬件，也可以识别固定
机器码序列并融合为专用微操作，但必须保持架构可见结果、内存副作用、异常行为和
提交顺序等价。不得跳过 CoreMark 调用、伪造 COUNTER、CRC、输出或完成条件。

专用性能仿真仅对端口时序做两项等价加速：UART 写直接进入校验字节流，
COUNTER 毫秒值由 CPU 周期分频得到。CoreMark timed section 不访问 UART，因此
观察点的 CPU 周期差与完整外设模型一致。对 UART 本身或跨时钟桥的修改仍必须
使用普通 CPU-only 回归，不能用本模式验收。

## 2. 首次基线

```sh
./coremark-perf/run_coremark_verilator.sh estimate --tag baseline
```

一次运行完成 16 次迭代，日志必须包含：

```text
>>> [COREMARK_SNAPSHOT] iterations=8
>>> [COREMARK_SNAPSHOT] iterations=16
>>> [COREMARK_CRC] crclist=e714 crcmatrix=1fd7 crcstate=8e3a
>>> [COREMARK_RUN] iterations=16 validity=short-run
>>> [PASS]
```

结果目录保存：

```text
coremark-perf/results/baseline-estimate/
├── firmware/
│   ├── rtthread.elf
│   ├── rtthread.irom.coe
│   ├── rtthread.bram.coe
│   └── rtthread.disasm
├── verilator_i16.log
├── estimate_10000.json
├── estimate_10000.md
├── protected_sources.sha256
├── port.sha256
├── firmware.sha256
├── rtl.sha256
└── run.meta
```

其中 `run.meta` 记录模式、采样点、自动解析出的 `core_bench_list` 地址、工具链和
仿真覆盖参数。不要混用不同目录中的固件、RTL 哈希和日志。

## 3. 外推解释

第 N 个观察点位于第 N 次迭代的第二次 `core_bench_list` 调用入口。入口按 WB
退休事件识别，避免流水线停顿使 EX valid/PC 保持时重复计数。虽然观察点不是
循环末尾，但第 8 与第 16 个同相位观察点之间恰好包含 8 个完整迭代。分析器按
差值计算每次迭代增量，再从 16 次运行的最终累计统计增加 9984 个增量。

分析器还把观察点得到的 `cycles/iteration × 运行次数` 与 CoreMark 自身的
`Total ticks` 对照。考虑 COUNTER 的 1 ms 分辨率和 timed section 边界上的少量
指令后仍不一致时，报告会失败，防止错误观察点产生看似合理的外推结果。

报告中的两个时间含义不同：

- `10000 次稳态时间`：只按稳态 `cycles/iteration × 10000` 换算，最接近
  CoreMark timed section；
- `外推端到端时间`：保留 RT-Thread 启动、autorun 线程调度、初始化、输出和返回
  shell 的固定开销，适合估算整次 CPU-only 仿真。

外推假设每次迭代进入稳定的确定性路径。新增优化若包含预热、自适应状态、周期性
行为或饱和计数器，先检查 8/16 两个观察点的增量是否稳定。日常与最终
验收都不运行 `full`；只在斜率不稳定、优化状态无法在 16 次内收敛，或
分析器无法证明外推一致时，才例外运行一次 `stage` 定位问题。若仍不能建立
可靠的短测外推，应放弃或重设该优化，不用长时间仿真掩盖不稳定行为。

## 4. 每轮优化

每轮建议依次执行：

1. 修改移植接口或 CPU RTL；
2. 运行 `estimate --tag optNN`；
3. 比较 CRC、`cycles/iteration`、稳态 CPI、load-use、EX busy、L0 命中率和
   10000 次外推时间；
4. 确认 `protected_sources.sha256` 未变化；
5. 确认两个观察点的增量稳定后保留该轮结果，直接进入下一轮。

常规优化轮次只运行 `estimate`，不把 `stage` 当作候选版的固定步骤，也不运行
`full`。`stage` 仅用于第 3 节所述的异常定位，不用于常规性能确认。

同一 tag 会覆盖同名结果目录。需要保留历史时使用新 tag。

## 5. 最终高效验收

```sh
./coremark-perf/run_coremark_verilator.sh estimate --tag final
```

最终验收仍使用 16 次短测和 10000 次外推，不运行 `full`。只有同时满足
以下条件才通过：

- 日志包含第 8 和第 16 次观察点；
- 三项 CRC 完全匹配 `e714 / 1fd7 / 8e3a`；
- 出现 `iterations=16 validity=short-run` 和 `[PASS]`；
- 观察点周期与 CoreMark `Total ticks` 的一致性检查通过；
- `protected_sources.sha256` 未变化，固件和 RTL 哈希与本次日志属于同一结果目录；
- 不出现 CRC error、`Errors detected`、未知 seeds 或仿真超时。

`estimate_10000.md/json` 保存最终外推结果。报告必须明确标记为短测
外推，不宣称为 10000 次实跑或官方完整 CoreMark 成绩。

## 6. Vivado 时序

当前 Ubuntu/VMware 开发环境已配置从 `scripts/vivado-host` 通过 SSH 调用
Windows 宿主机上的 Vivado，无需在 Ubuntu 内另行安装 Vivado。首先检查
SSH、共享仓库路径和 Vivado 自动探测：

```sh
./scripts/vivado-host check
```

`check` 必须打印 Windows 侧的仓库路径、Vivado 可执行文件和版本，并以
0 退出。连通后，硬件优化轮次先做 RTL 综合；只对准备保留的候选版做完整
布局布线：

```sh
# 只检查 RTL 综合
./scripts/vivado-host build synth

# 重新综合并完成布局布线，生成 timing summary
./scripts/vivado-host build impl
```

`build` 会在工程不存在时自动重建 `vivado/digital_twin.xpr`，并在每次
构建前用 `rt-thread/bsp/mycpu/build/rtthread.irom.coe` 和
`rt-thread/bsp/mycpu/build/rtthread.bram.coe` 刷新 IROM/BRAM output
products。因此应先确认当前 RT-Thread 固件已生成，不要使用其他
结果目录中的历史 COE。

综合、实现和 bitstream 一律使用默认策略。不传入
`Performance_NetDelay_high` 或其他高强度实现策略，避免在布局布线上消耗
过多优化时间。

需要下板验证时再生成 bitstream：

```sh
./scripts/vivado-host build bitstream
```

实现完成后，Windows 和 Ubuntu 通过共享目录看到同一份结果，可在 Ubuntu
中直接把 timing summary 合并到 estimate 报告：

```sh
python3 coremark-perf/tools/analyze_coremark_run.py \
  coremark-perf/results/opt01-estimate \
  --timing-report vivado/digital_twin.runs/impl_1/top_timing_summary_routed.rpt
```

分析器给出的 Fmax 是基于目标周期和 WNS 的近似值。最终频率仍以实现后 timing
summary、时钟约束和 route status 为准；不要编辑或提交 `.runs`、`.cache`、
`.gen`、`.sim` 中的生成物。
