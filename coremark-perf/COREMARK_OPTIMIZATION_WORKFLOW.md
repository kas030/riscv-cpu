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

一次运行完成 2 次迭代，日志必须包含：

```text
>>> [COREMARK_SNAPSHOT] iterations=1
>>> [COREMARK_SNAPSHOT] iterations=2
>>> [COREMARK_CRC] crclist=e714 crcmatrix=1fd7 crcstate=8e3a
>>> [COREMARK_RUN] iterations=2 validity=short-run
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
├── verilator_i2.log
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

第 N 个观察点位于第 N 次迭代的第二次 `core_bench_list` 调用入口。虽然它不是
循环末尾，但第 1 与第 2 个同相位观察点之间恰好包含 1 个完整迭代。分析器按
差值计算每次迭代增量，再从 2 次运行的最终累计统计增加 9998 个增量。

报告中的两个时间含义不同：

- `10000 次稳态时间`：只按稳态 `cycles/iteration × 10000` 换算，最接近
  CoreMark timed section；
- `外推端到端时间`：保留 RT-Thread 启动、autorun 线程调度、初始化、输出和返回
  shell 的固定开销，适合估算整次 CPU-only 仿真。

外推假设每次迭代进入稳定的确定性路径。新增优化若包含预热、自适应状态、周期性
行为或饱和计数器，必须用 `stage` 和 `full` 复核，不能只比较 1/2 斜率。

## 4. 每轮优化

每轮建议依次执行：

1. 修改移植接口或 CPU RTL；
2. 运行 `estimate --tag optNN`；
3. 比较 CRC、`cycles/iteration`、稳态 CPI、load-use、EX busy、L0 命中率和
   10000 次外推时间；
4. 确认 `protected_sources.sha256` 未变化；
5. 有明确收益后运行 `stage --tag optNN-stage`；
6. 阶段结果稳定后运行 `full --tag optNN-full`。

同一 tag 会覆盖同名结果目录。需要保留历史时使用新 tag。

## 5. 正式回归

```sh
./coremark-perf/run_coremark_verilator.sh full --tag final
```

正式回归只有同时满足以下条件才通过：

- 命令和输出均确认 10000 次；
- 三项官方 CRC 完全匹配；
- `Total time` 至少 10 秒；
- 出现 `Correct operation validated`；
- 不出现 CRC error、最短时间 error、`Errors detected` 或未知 seeds；
- 返回 RT-Thread `msh >`。

`actual_10000.md/json` 保存实跑结果。短测外推不得作为正式成绩替代它。

## 6. Vivado 时序

硬件优化后需用当前 RTL 重新执行 `vivado/digital_twin.xpr` 的综合和实现。完成后
可把 timing summary 合并到任意 estimate/full 报告：

```sh
python3 coremark-perf/tools/analyze_coremark_run.py \
  coremark-perf/results/opt01-estimate \
  --timing-report vivado/digital_twin.runs/impl_1/top_timing_summary_routed.rpt
```

分析器给出的 Fmax 是基于目标周期和 WNS 的近似值。最终频率仍以实现后 timing
summary、时钟约束和 route status 为准；不要编辑或提交 `.runs`、`.cache`、
`.gen`、`.sim` 中的生成物。
