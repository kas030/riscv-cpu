# =============================================================
# tests/Makefile —— 一键编译所有 RV32I 测试为 .coe / .mif
#
# 依赖：
#   - RISC-V 工具链：riscv32-unknown-elf-gcc / objcopy（或 riscv-none-embed-）
#   - Python3（用于 bin2coe.py）
#
# 用法：
#   make                  # 编译全部
#   make t10_fibonacci    # 单个目标
#   make clean
#   make install          # 把生成的 irom.coe 复制到 IP 目录
# =============================================================

# 优先尝试常见前缀
CROSS ?= riscv32-unknown-elf-
ifeq ($(shell which $(CROSS)gcc 2>/dev/null),)
  CROSS = riscv-none-embed-
endif
ifeq ($(shell which $(CROSS)gcc 2>/dev/null),)
  CROSS = riscv64-unknown-elf-
endif

CC      = $(CROSS)gcc
LD      = $(CROSS)ld
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
PYTHON ?= python3

CFLAGS  = -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
          -ffreestanding -fno-builtin -O1 -g
LDFLAGS = -T linker/link.ld -Wl,-Map=$(@:.elf=.map)

BUILD   = build
TOOLS   = tools

# 按名称生成并构建单条 Zb 指令测试；不加入默认 all。
ZB_INSN ?=
ZB_ENCODING ?=
ZB_SLUG = $(subst .,_,$(ZB_INSN))
ZB_NAME = zb_$(ZB_SLUG)
ZB_SRC = $(BUILD)/$(ZB_NAME).S
ZB_ENCODING_ARG = $(if $(strip $(ZB_ENCODING)),--encoding $(ZB_ENCODING),)

# 收集所有 .S
SRCS := $(wildcard tier1_basic/*.S tier2_hazard/*.S tier3_perf/*.S tier4_bench/*.S)
NAMES := $(notdir $(SRCS:.S=))

# 主目标 = 所有 .coe 与 .mif
COES := $(addprefix $(BUILD)/, $(addsuffix .coe, $(NAMES)))
MIFS := $(addprefix $(BUILD)/, $(addsuffix .mif, $(NAMES)))
DUMPS := $(addprefix $(BUILD)/, $(addsuffix .dump, $(NAMES)))

.PHONY: all clean install help dirs zb-test $(NAMES)

all: dirs $(COES) $(MIFS) $(DUMPS)
	@echo ""
	@echo "==== Build summary ===="
	@ls -1 $(BUILD)/*.coe 2>/dev/null | wc -l | xargs echo "  .coe count :"
	@ls -1 $(BUILD)/*.mif 2>/dev/null | wc -l | xargs echo "  .mif count :"
	@echo "  artifacts  : $(BUILD)/"

dirs:
	@mkdir -p $(BUILD)

# 单测试快捷目标，例如 `make t10_fibonacci`
$(NAMES): %: dirs $(BUILD)/%.coe $(BUILD)/%.mif $(BUILD)/%.dump

# 在 4 个 tier 子目录里寻找对应 .S 文件
define find_src
$(firstword $(wildcard tier1_basic/$(1).S tier2_hazard/$(1).S tier3_perf/$(1).S tier4_bench/$(1).S))
endef

.SECONDEXPANSION:
.SECONDARY:  # 保留中间产物（.elf/.bin）以便调试

$(BUILD)/%.elf: $$(call find_src,%) linker/link.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

$(BUILD)/%.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary --only-section=.text.init --only-section=.text \
	           --only-section=.rodata $< $@

$(BUILD)/%.coe: $(BUILD)/%.bin
	$(PYTHON) $(TOOLS)/bin2coe.py $< $@ --depth 4096

$(BUILD)/%.mif: $(BUILD)/%.bin
	$(PYTHON) $(TOOLS)/bin2coe.py $< $@ --mif --depth 4096

$(BUILD)/%.dump: $(BUILD)/%.elf
	$(OBJDUMP) -d -M no-aliases $< > $@

# 示例：make zb-test ZB_INSN=ror
# 题面编码不同时：make zb-test ZB_INSN=ror ZB_ENCODING=0x6062d3b3
zb-test: dirs
	@if [ -z "$(strip $(ZB_INSN))" ]; then \
		echo "error: set ZB_INSN, for example: make zb-test ZB_INSN=ror"; \
		exit 2; \
	fi
	$(PYTHON) zb_training/tools/zb_tool.py generate "$(ZB_INSN)" \
		--output "$(ZB_SRC)" $(ZB_ENCODING_ARG)
	$(CC) $(CFLAGS) -T linker/link.ld -Wl,-Map=$(BUILD)/$(ZB_NAME).map \
		-o $(BUILD)/$(ZB_NAME).elf $(ZB_SRC)
	$(OBJCOPY) -O binary --only-section=.text.init --only-section=.text \
		--only-section=.rodata $(BUILD)/$(ZB_NAME).elf $(BUILD)/$(ZB_NAME).bin
	$(PYTHON) $(TOOLS)/bin2coe.py $(BUILD)/$(ZB_NAME).bin \
		$(BUILD)/$(ZB_NAME).coe --depth 4096
	$(PYTHON) $(TOOLS)/bin2coe.py $(BUILD)/$(ZB_NAME).bin \
		$(BUILD)/$(ZB_NAME).mif --mif --depth 4096
	$(OBJDUMP) -d -M no-aliases $(BUILD)/$(ZB_NAME).elf > $(BUILD)/$(ZB_NAME).dump
	@echo "Built Zb test: $(BUILD)/$(ZB_NAME).coe"

# 拷贝指定 testcase 的 irom.coe 到 IP 目录，覆盖现有 mem init
TARGET ?= t10_fibonacci
install: $(BUILD)/$(TARGET).coe
	@echo "Installing $< as IROM..."
	cp $< ../digital_twin.srcs/sources_1/imports/test_src/irom.coe
	cp $< ../digital_twin.srcs/sources_1/imports/JYD2025/coe/test_src/irom.coe || true
	cp $< ../digital_twin.srcs/sources_1/imports/Desktop/irom.coe || true
	@echo "Done. Re-run synthesis/simulation in Vivado."

clean:
	rm -rf $(BUILD)

help:
	@echo "Targets:"
	@echo "  make             - build all .coe/.mif/.dump"
	@echo "  make tNN_xxxxx   - build a single test (any name in tier*)"
	@echo "  make zb-test ZB_INSN=ror [ZB_ENCODING=0x...] - build one Zb test"
	@echo "  make install TARGET=t10_fibonacci  - copy chosen .coe to IROM IP dir"
	@echo "  make clean       - remove build/"
