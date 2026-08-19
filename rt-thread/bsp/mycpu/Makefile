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
COREMARK_SMOKE_BUILD ?= build/coremark-smoke
COREMARK_SMOKE_ITERATIONS ?= 24
COREMARK_ARCHIVE := $(ROOT)/handouts/coremark（已解压版本）.zip
COREMARK_PREPARE := prepare_coremark_handout.py
COREMARK_PREPARED := $(BUILD)/coremark-handout
COREMARK_SRC := $(COREMARK_PREPARED)/src
COREMARK_STAMP := $(COREMARK_PREPARED)/.prepared

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
# 材料版正式配置固定执行 18000 次；短测使用独立 BUILD 目录覆盖该值。
COREMARK_ITERATIONS ?= 18000
# 性能开发专用：在 RT-Thread 调度器启动后由独立线程直接调用移植入口，
# 省去 CPU-only 仿真中的逐字节 UART 命令注入；正式固件默认关闭。
COREMARK_AUTORUN ?= 0
COREMARK_AUTORUN_FLAGS := $(if $(filter 1,$(COREMARK_AUTORUN)),\
	-DCOREMARK_PERF_AUTORUN=1,)

# ---- 编译对象：内核 11 个 + libcpu common 4 个 + bsp 4 个 + finsh 3 个
KSRC := clock cpu idle ipc irq kservice mem object scheduler thread timer
KOBJ := $(KSRC:%=$(BUILD)/k_%.o)
LIBOBJ := $(BUILD)/cpuport.o $(BUILD)/context.o
BSPOBJ := $(BUILD)/board.o $(BUILD)/bme280.o $(BUILD)/main.o $(BUILD)/entry.o
FINSHOBJ := $(BUILD)/finsh_shell.o $(BUILD)/finsh_cmd.o $(BUILD)/finsh_msh.o
# ---- handouts CoreMark：5 个核心源 + 材料自带平台/打印代码 + autorun 包装
COREOBJ := $(BUILD)/cm_list.o $(BUILD)/cm_main.o $(BUILD)/cm_matrix.o \
	           $(BUILD)/cm_state.o $(BUILD)/cm_util.o $(BUILD)/cm_portme.o \
	           $(BUILD)/cm_printf.o $(BUILD)/cm_cvt.o $(BUILD)/cm_cmd.o
OBJS := $(KOBJ) $(LIBOBJ) $(BSPOBJ) $(FINSHOBJ) $(COREOBJ)
ALL_DEPS := $(OBJS:.o=.d)
CORE_DEPS := $(COREOBJ:.o=.d)
# 分支升级后可能残留指向已移除 coremark/ 目录的旧依赖缓存；只接纳不含
# 该路径的 CoreMark .d，避免旧生成物阻断材料源码的首次重建。
SAFE_CORE_DEPS := $(foreach dep,$(wildcard $(CORE_DEPS)),\
	$(if $(findstring coremark/,$(file <$(dep))),,$(dep)))
DEPS := $(filter-out $(CORE_DEPS),$(ALL_DEPS)) $(SAFE_CORE_DEPS)

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

# ---- CoreMark 公共编译参数。源码由校验脚本直接从 handouts ZIP 生成；
#      算法文件保持材料原文，脚本只实现材料中预留的计时/UART平台钩子。
#      MAIN_HAS_NOARGC=1 与材料 core_portme.c 的 coremark_main(void) 调用一致。
CORE_CFLAGS_COMMON := $(ARCH_FLAGS) -I. -I$(KERNEL)/include -I$(FINSH) \
	-MMD -MP -I$(COREMARK_SRC) -Dmain=coremark_main -DPERFORMANCE_RUN=1 \
	-DTOTAL_DATA_SIZE=2000 -DITERATIONS=$(COREMARK_ITERATIONS) \
	-DMAIN_HAS_NOARGC=1 -DHAS_FLOAT=1 -DHAS_STDIO=0 -DHAS_PRINTF=0 \
	-DFLAGS_STR=\"handouts-coremark-rv32im-zicsr-O3\"
CORE_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_OPT)
CORE_LIST_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_LIST_OPT)
CORE_MATRIX_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_MATRIX_OPT)
CORE_STATE_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_STATE_OPT)
CORE_UTIL_CFLAGS := $(CORE_CFLAGS_COMMON) $(CORE_UTIL_OPT)

# 每个 BUILD 目录都从指定 ZIP 独立生成编译源和 provenance.json。
$(COREMARK_STAMP): $(COREMARK_ARCHIVE) $(COREMARK_PREPARE) | $(BUILD)
	$(PYTHON) $(COREMARK_PREPARE) $(COREMARK_ARCHIVE) $(COREMARK_PREPARED)

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

$(BUILD)/cm_list.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_LIST_CFLAGS) -c $(COREMARK_SRC)/core_list_join.c -o $@

$(BUILD)/cm_main.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $(COREMARK_SRC)/core_main.c -o $@

$(BUILD)/cm_matrix.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_MATRIX_CFLAGS) -c $(COREMARK_SRC)/core_matrix.c -o $@

$(BUILD)/cm_state.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_STATE_CFLAGS) -c $(COREMARK_SRC)/core_state.c -o $@

$(BUILD)/cm_util.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_UTIL_CFLAGS) -c $(COREMARK_SRC)/core_util.c -o $@

$(BUILD)/cm_portme.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $(COREMARK_SRC)/core_portme.c -o $@

$(BUILD)/cm_printf.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $(COREMARK_SRC)/ee_printf.c -o $@

$(BUILD)/cm_cvt.o: $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt | $(BUILD)
	$(CC) $(CORE_CFLAGS) -c $(COREMARK_SRC)/cvt.c -o $@

$(BUILD)/cm_cmd.o: coremark_cmd.c $(COREMARK_STAMP) rtconfig.h $(BUILD)/coremark_config.txt $(BUILD)/coremark_autorun_config.txt | $(BUILD)
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
	env -u CPATH $(ROOT)/sim_cpu_only/run_verilator.sh \
		IROM_COE=$(abspath $(SIM_DEMO_BUILD)/rtthread.irom.coe) \
		BRAM_COE=$(abspath $(SIM_DEMO_BUILD)/rtthread.bram.coe) \
		PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
		STOP_NS=$(STOP_NS) PROGRESS_NS=$(PROGRESS_NS) TRACE=0 \
		COREMARK_VERIFY=$(COREMARK_VERIFY)

coremark-smoke:
	$(MAKE) all BUILD=$(COREMARK_SMOKE_BUILD) \
		COREMARK_ITERATIONS=$(COREMARK_SMOKE_ITERATIONS) COREMARK_AUTORUN=0
	env -u CPATH $(ROOT)/sim_cpu_only/run_verilator.sh \
		IROM_COE=$(abspath $(COREMARK_SMOKE_BUILD)/rtthread.irom.coe) \
		BRAM_COE=$(abspath $(COREMARK_SMOKE_BUILD)/rtthread.bram.coe) \
		PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
		CPU_FREQ_MHZ=200.0 STOP_NS=350000000 PROGRESS_NS=0 TRACE=0 \
		COREMARK_VERIFY=1 COREMARK_ITERATIONS=$(COREMARK_SMOKE_ITERATIONS)

size: $(BUILD)/rtthread.elf
	@$(SIZE) $<

clean:
	rm -rf $(BUILD)

-include $(DEPS)
