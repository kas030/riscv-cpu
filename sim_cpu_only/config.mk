# CPU-only 仿真默认输入。
# 路径相对于 sim_cpu_only/ 解析，因为 run_verilator.sh 会进入该目录运行 make。
IROM_COE := ../sim/coe/irom.coe
BRAM_COE := ../sim/coe/bram.coe

# 留空则按 PASS_LED / FAIL_LED 判定；非空时额外要求最终 LED 等于 EXPECTED_LED。
EXPECTED_LED :=
PASS_LED := 01221C08
FAIL_LED := 24181824

# TRACE := 1 时生成 FST 波形：sim_cpu_only/build/wave.fst。
TRACE := 0

# 仿真超时时间，单位 ns。抓波形时建议改小，例如 1000000。
STOP_NS := 1000000000

# 进度打印间隔，单位 ns。设为 0 可关闭周期性进度输出。进度只显示在终端，不写入日志。
PROGRESS_NS := 10000000
