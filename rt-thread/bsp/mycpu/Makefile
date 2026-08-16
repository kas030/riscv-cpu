# RT-Thread Nano 3.1.5 —— mycpu 平台构建与仿真
#
# 用法（在 rt-thread/bsp/mycpu/ 下）：
#   make                构建 elf/bin/coe
#   make size           打印段尺寸（IROM 预算 64 KiB，linker.ld 有 ASSERT 把关）
#   make run            完整仿真（仅该目标启用 3 秒 LED 完成线程）
#   make run DEMO_RUN_MS=500 STOP_NS=1500000000   快速仿真
#   make coremark-smoke  短迭代 CRC/命令返回验收（不作为正式成绩）
#   make clean

ROOT := ../../..
KERNEL := ../../kernel
FINSH := ../../components/finsh

# ---- 工具链：默认尝试 ~/.local/riscv-tc/bin，可用 CROSS 或单独工具变量覆盖
TOOLCHAIN_DIR ?= $(HOME)/.local/riscv-tc/bin
PATH := $(TOOLCHAIN_DIR):$(PATH)
export PATH

CROSS ?= riscv32-unknown-elf-
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE := $(CROSS)size
PYTHON ?= python3

BUILD := build
SIM_DEMO_BUILD ?= build/sim-demo

ARCH_FLAGS := -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
	-msmall-data-limit=0
OPT := -Os -ffunction-sections -fdata-sections -ffreestanding
CORE_OPT ?= -O3 -funroll-loops -mbranch-cost=1 -fsched-pressure -ftracer \
	-ffunction-sections -fdata-sections -ffreestanding
# 链表、矩阵和 CRC 热点从强制展开中获益；状态机的控制流较密，沿用
# 盈利性展开反而更快。分文件变量也便于性能迭代时显式记录实际参数。
CORE_LIST_OPT ?= -O3 -funroll-all-loops -mbranch-cost=1 -fsched-pressure -ftracer \
	-ffunction-sections -fdata-sections -ffreestanding
CORE_MATRIX_OPT ?= $(CORE_LIST_OPT)
CORE_STATE_OPT ?= $(CORE_OPT)
CORE_UTIL_OPT ?= $(CORE_LIST_OPT)
CFLAGS := $(ARCH_FLAGS) $(OPT) -I. -I$(KERNEL)/include -I$(FINSH) -MMD -MP
LDFLAGS := $(ARCH_FLAGS) -nostdlib -nostartfiles -static \
	-Wl,--gc-sections -Wl,--build-id=none -T linker.ld
# BME280 的 64 位定点气压补偿需要 RV32IM/ilp32 对应的 libgcc 辅助例程。
LIBGCC = $(shell $(CC) $(ARCH_FLAGS) -print-libgcc-file-name)

# ---- 板卡默认禁用 3 秒 LED 完成线程；仅 run 仿真目标开启
DEMO_RUN_MS ?= 3000
DEMO_FINISH_THREAD ?= 0

# ---- 仿真参数
STOP_NS ?= 4000000000
PROGRESS_NS ?= 0
# 仿真验收开关：1 时向 UART 注入 coremark 命令并自动校验 (tb_cpu_only.sv)
COREMARK_VERIFY ?= 0
# 200 MHz 下 10000 次按 16 次短测外推约 13.98 秒，满足官方“正式成绩至少
# 运行 10 秒”规则，同时保留在赛题 30 秒满分区间内。
COREMARK_ITERATIONS ?= 10000
# 性能开发专用：在 RT-Thread 调度器启动后由独立线程直接调用移植入口，
# 省去 CPU-only 仿真中的逐字节 UART 命令注入；正式固件默认关闭。
COREMARK_AUTORUN ?= 0
COREMARK_RUN_ITERATIONS ?= $(COREMARK_ITERATIONS)
COREMARK_AUTORUN_FLAGS := $(if $(filter 1,$(COREMARK_AUTORUN)),\
	-DCOREMARK_PERF_AUTORUN=1 -DCOREMARK_RUN_ITERATIONS=$(COREMARK_RUN_ITERATIONS),)

# ---- 编译对象：内核 11 个 + libcpu common 4 个 + bsp 4 个 + finsh 3 个
KSRC := clock cpu idle ipc irq kservice mem object scheduler thread timer
KOBJ := $(KSRC:%=$(BUILD)/k_%.o)
LIBOBJ := $(BUILD)/cpuport.o $(BUILD)/context.o
BSPOBJ := $(BUILD)/board.o $(BUILD)/bme280.o $(BUILD)/main.o $(BUILD)/entry.o
FINSHOBJ := $(BUILD)/finsh_shell.o $(BUILD)/finsh_cmd.o $(BUILD)/finsh_msh.o
# ---- 官方 EEMBC CoreMark 1.0：5 个核心源 + 平台移植 + msh 导出
COREOBJ := $(BUILD)/cm_list.o $(BUILD)/cm_main.o $(BUILD)/cm_matrix.o \
           $(BUILD)/cm_state.o $(BUILD)/cm_util.o $(BUILD)/cm_portme.o \
           $(BUILD)/cm_cmd.o
OBJS := $(KOBJ) $(LIBOBJ) $(BSPOBJ) $(FINSHOBJ) $(COREOBJ)
DEPS := $(OBJS:.o=.d)

.PHONY: all run coremark-smoke size clean FORCE

all: $(BUILD)/rtthread.irom.coe $(BUILD)/rtthread.bram.coe
	@$(SIZE) $(BUILD)/rtthread.elf

$(BUILD):
	@mkdir -p $@

$(BUILD)/k_%.o: $(KERNEL)/src/%.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/cpuport.o: $(KERNEL)/libcpu/risc-v/common/cpuport.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/context.o: $(KERNEL)/libcpu/risc-v/common/context_gcc.S rtconfig.h | $(BUILD)
	$(CC) $(ARCH_FLAGS) -I. -I$(KERNEL)/include -c $< -o $@

$(BUILD)/entry.o: entry_gcc.S | $(BUILD)
	$(CC) $(ARCH_FLAGS) -c $< -o $@

$(BUILD)/board.o: board.c board.h rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/bme280.o: bme280.c bme280.h rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/finsh_shell.o: $(FINSH)/shell.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/finsh_cmd.o: $(FINSH)/cmd.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/finsh_msh.o: $(FINSH)/msh.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# ---- CoreMark 公共编译参数（各算法的展开策略由上方 CORE_*_OPT 指定；
#      -Dmain=coremark_main 把 core_main.c 的 main 重命名为内部入口，
#      coremark_cmd.c 负责 msh 缺省参数和可选的性能自动运行线程。
#      core_main.c/coremark.h 另含单精度计时与无 libc 输出适配，差异说明见
#      rt-thread/README.md）
CORE_CFLAGS_COMMON := $(ARCH_FLAGS) -I. -I$(KERNEL)/include -I$(FINSH) \
	-MMD -MP -Icoremark -Dmain=coremark_main -DPERFORMANCE_RUN=1 \
	-DTOTAL_DATA_SIZE=2000 -DITERATIONS=$(COREMARK_ITERATIONS) \
	-DHAS_FLOAT=1 -DHARDWARE_FPU_SINGLE=1
CORE_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_OPT)
CORE_LIST_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_LIST_OPT)
CORE_MATRIX_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_MATRIX_OPT)
CORE_STATE_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_STATE_OPT)
CORE_UTIL_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_UTIL_OPT)

# COREMARK_ITERATIONS/flags 变化时强制重编全部 CoreMark 对象。
$(BUILD)/coremark_config.txt: FORCE | $(BUILD)
	@printf '%s\n' 'default=$(CORE_CFLAGS)' \
		'list=$(CORE_LIST_CFLAGS)' \
		'matrix=$(CORE_MATRIX_CFLAGS)' \
		'state=$(CORE_STATE_CFLAGS)' \
		'util=$(CORE_UTIL_CFLAGS)' > $@.tmp \
		&& (cmp -s $@ $@.tmp || mv $@.tmp $@) && rm -f $@.tmp

$(BUILD)/coremark_autorun_config.txt: FORCE | $(BUILD)
	@printf '%s\n' '$(COREMARK_AUTORUN_FLAGS)' > $@.tmp \
		&& (cmp -s $@ $@.tmp || mv $@.tmp $@) && rm -f $@.tmp

$(BUILD)/cm_list.o: coremark/core_list_join.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_LIST_CFLAGS) -c $< -o $@

$(BUILD)/cm_main.o: coremark/core_main.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $< -o $@

$(BUILD)/cm_matrix.o: coremark/core_matrix.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_MATRIX_CFLAGS) -c $< -o $@

$(BUILD)/cm_state.o: coremark/core_state.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_STATE_CFLAGS) -c $< -o $@

$(BUILD)/cm_util.o: coremark/core_util.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_UTIL_CFLAGS) -c $< -o $@

$(BUILD)/cm_portme.o: coremark/core_portme.c coremark/coremark.h coremark/core_portme.h rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $< -o $@

$(BUILD)/cm_cmd.o: coremark_cmd.c rtconfig.h $(BUILD)/coremark_config.txt $(BUILD)/coremark_autorun_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) $(COREMARK_AUTORUN_FLAGS) -c $< -o $@

# main.c 编译配置变化时强制重编（内容不变则不动时间戳）
$(BUILD)/main_config.txt: FORCE | $(BUILD)
	@mkdir -p $(BUILD) && printf '%s\n' \
		'DEMO_RUN_MS=$(DEMO_RUN_MS)' \
		'DEMO_FINISH_THREAD=$(DEMO_FINISH_THREAD)' > $@.tmp \
		&& (cmp -s $@ $@.tmp || mv $@.tmp $@) && rm -f $@.tmp

$(BUILD)/main.o: main.c board.h bme280.h rtconfig.h $(BUILD)/main_config.txt $(BUILD)/coremark_autorun_config.txt | $(BUILD)
	$(CC) $(CFLAGS) $(COREMARK_AUTORUN_FLAGS) -DDEMO_RUN_MS=$(DEMO_RUN_MS) \
		-DDEMO_FINISH_THREAD=$(DEMO_FINISH_THREAD) -c $< -o $@

$(BUILD)/rtthread.elf: $(OBJS) linker.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LIBGCC)

$(BUILD)/rtthread.irom.bin: $(BUILD)/rtthread.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/rtthread.bram.bin: $(BUILD)/rtthread.elf
	$(OBJCOPY) -O binary --only-section=.rodata --only-section=.data $< $@

$(BUILD)/rtthread.irom.coe: $(BUILD)/rtthread.irom.bin
	$(PYTHON) $(ROOT)/verification/tools/bin_to_coe.py --max-words 16384 $< $@

$(BUILD)/rtthread.bram.coe: $(BUILD)/rtthread.bram.bin
	$(PYTHON) $(ROOT)/verification/tools/bin_to_coe.py --max-words 65536 $< $@

run:
	$(MAKE) all BUILD=$(SIM_DEMO_BUILD) DEMO_FINISH_THREAD=1
	$(ROOT)/sim_cpu_only/run_verilator.sh \
		IROM_COE=$(abspath $(SIM_DEMO_BUILD)/rtthread.irom.coe) \
		BRAM_COE=$(abspath $(SIM_DEMO_BUILD)/rtthread.bram.coe) \
		PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
		STOP_NS=$(STOP_NS) PROGRESS_NS=$(PROGRESS_NS) TRACE=0 \
		COREMARK_VERIFY=$(COREMARK_VERIFY)

coremark-smoke: $(BUILD)/rtthread.irom.coe $(BUILD)/rtthread.bram.coe
	$(ROOT)/sim_cpu_only/run_verilator.sh \
		IROM_COE=$(abspath $(BUILD)/rtthread.irom.coe) \
		BRAM_COE=$(abspath $(BUILD)/rtthread.bram.coe) \
		PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
		CPU_FREQ_MHZ=200.0 STOP_NS=350000000 PROGRESS_NS=0 TRACE=0 \
		COREMARK_VERIFY=1

size: $(BUILD)/rtthread.elf
	@$(SIZE) $<

clean:
	rm -rf $(BUILD)

-include $(DEPS)
