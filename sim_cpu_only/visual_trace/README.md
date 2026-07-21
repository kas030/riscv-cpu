# CPU visual trace

`run_visual_trace.sh` 复用 `tb_cpu_only.sv` 的 IROM、BRAM、MMIO 和完成判定；
`visual_trace_probe.sv` 通过 `bind` 只读采样 `mycpu`，不会进入综合，也不会改变
CPU 固定端口。frame 的 `signals`/`tags` 是时钟沿后 `#1` 的稳定状态，
`edgeEvents` 是该沿刚发生的退休、store、CSR 和 redirect 副作用。

```sh
./sim_cpu_only/run_visual_trace.sh \
  vivado/tests/build/t08_load_use.coe \
  site/public/generated/cpu-visualizer/traces/t08_load_use
```

生成器仅在 CPU-only 日志明确 PASS、tag 生命周期/退休顺序/副作用检查通过且
RTL 摘要与 graph manifest 一致时发布分块 trace。

运行 `./sim_cpu_only/run_all_visual_traces.sh` 可重建站点发布的八个场景；每个
场景还必须通过独立顺序 RV32IM/Zicsr 参考解释器对拍。运行
`./sim_cpu_only/check_visual_trace_equivalence.sh <image>` 可比较 trace 开关两侧
的 16 项结果和执行统计。
