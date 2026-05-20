# CPU-only 仿真默认输入。
# 路径相对于 sim_cpu_only/ 解析，因为 run_verilator.sh 会进入该目录运行 make。
IROM_COE := ../sim/coe/irom.coe
DRAM_COE := ../sim/coe/dram.coe

# 留空则不比较 LED。示例：EXPECTED_LED := C0DEC0DE
EXPECTED_LED :=

# TRACE := 1 时生成 FST 波形：sim_cpu_only/build/wave.fst。
TRACE := 0

# 仿真超时时间，单位 ns。抓波形时建议改小，例如 1000000。
STOP_NS := 400000000

# 进度打印间隔，单位 ns。设为 0 可关闭周期性进度输出。进度只显示在终端，不写入日志。
PROGRESS_NS := 10000000
