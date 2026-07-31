# RT-Thread Nano 3.1.5 —— mycpu 平台构建与仿真
#
# 用法（在 rt-thread/bsp/mycpu/ 下）：
#   make                构建 elf/bin/coe
#   make size           打印段尺寸（IROM 预算 16 KiB，linker.ld 有 ASSERT 把关）
#   make run            完整仿真（DEMO_RUN_MS=3000，STOP_NS=4s）
#   make run DEMO_RUN_MS=500 STOP_NS=1500000000   快速仿真
#   make clean

ROOT := ../../..
KERNEL := ../../kernel
FINSH := ../../components/finsh

# ---- 工具链：本机 riscv32-unknown-elf-gcc 位于 ~/.local/riscv-tc/bin（不在 PATH）
TOOLCHAIN_DIR ?= $(HOME)/.local/riscv-tc/bin
PATH := $(TOOLCHAIN_DIR):$(PATH)
export PATH

CROSS ?= riscv32-unknown-elf-
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE := $(CROSS)size

BUILD := build

ARCH_FLAGS := -march=rv32im_zicsr -mabi=ilp32 -mcmodel=medany \
	-msmall-data-limit=0 -mno-relax
OPT := -Os -ffunction-sections -fdata-sections -ffreestanding
CFLAGS := $(ARCH_FLAGS) $(OPT) -I. -I$(KERNEL)/include -I$(FINSH) -MMD -MP
LDFLAGS := -nostdlib -nostartfiles -static \
	-Wl,--gc-sections -Wl,--build-id=none -Wl,--no-relax -T linker.ld

# ---- 演示运行时长（毫秒），改值会触发 main.o 重编（见 demo_run_ms.txt 规则）
DEMO_RUN_MS ?= 3000

# ---- 仿真参数
STOP_NS ?= 4000000000
PROGRESS_NS ?= 0

# ---- 编译对象：内核 11 个 + libcpu common 4 个 + bsp 4 个 + finsh 3 个
KSRC := clock cpu idle ipc irq kservice mem object scheduler thread timer
KOBJ := $(KSRC:%=$(BUILD)/k_%.o)
LIBOBJ := $(BUILD)/cpuport.o $(BUILD)/context.o
BSPOBJ := $(BUILD)/board.o $(BUILD)/main.o $(BUILD)/entry.o
FINSHOBJ := $(BUILD)/finsh_shell.o $(BUILD)/finsh_cmd.o $(BUILD)/finsh_msh.o
OBJS := $(KOBJ) $(LIBOBJ) $(BSPOBJ) $(FINSHOBJ)
DEPS := $(OBJS:.o=.d)

.PHONY: all run size clean FORCE

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

$(BUILD)/finsh_shell.o: $(FINSH)/shell.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/finsh_cmd.o: $(FINSH)/cmd.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/finsh_msh.o: $(FINSH)/msh.c rtconfig.h | $(BUILD)
	$(CC) $(CFLAGS) -c $< -o $@

# DEMO_RUN_MS 变化时强制重编 main.o（内容不变则不动时间戳）
$(BUILD)/demo_run_ms.txt: FORCE | $(BUILD)
	@mkdir -p $(BUILD) && printf '%s' '$(DEMO_RUN_MS)' > $@.tmp \
		&& (cmp -s $@ $@.tmp || mv $@.tmp $@) && rm -f $@.tmp

$(BUILD)/main.o: main.c board.h rtconfig.h $(BUILD)/demo_run_ms.txt | $(BUILD)
	$(CC) $(CFLAGS) -DDEMO_RUN_MS=$(DEMO_RUN_MS) -c $< -o $@

$(BUILD)/rtthread.elf: $(OBJS) linker.ld
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

$(BUILD)/rtthread.irom.bin: $(BUILD)/rtthread.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/rtthread.bram.bin: $(BUILD)/rtthread.elf
	$(OBJCOPY) -O binary --only-section=.rodata --only-section=.data $< $@

$(BUILD)/rtthread.irom.coe: $(BUILD)/rtthread.irom.bin
	python3 $(ROOT)/verification/tools/bin_to_coe.py --max-words 4096 $< $@

$(BUILD)/rtthread.bram.coe: $(BUILD)/rtthread.bram.bin
	python3 $(ROOT)/verification/tools/bin_to_coe.py --max-words 65536 $< $@

run: $(BUILD)/rtthread.irom.coe $(BUILD)/rtthread.bram.coe
	$(ROOT)/sim_cpu_only/run_verilator.sh \
		IROM_COE=$(abspath $(BUILD)/rtthread.irom.coe) \
		BRAM_COE=$(abspath $(BUILD)/rtthread.bram.coe) \
		PASS_LED=C0DEC0DE FAIL_LED=DEADBEEF EXPECTED_LED=C0DEC0DE \
		STOP_NS=$(STOP_NS) PROGRESS_NS=$(PROGRESS_NS) TRACE=0

size: $(BUILD)/rtthread.elf
	@$(SIZE) $<

clean:
	rm -rf $(BUILD)

-include $(DEPS)
