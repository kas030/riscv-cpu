ROOT := ..
BUILD := build
CROSS ?= riscv64-unknown-elf-
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

TESTS := rv32i rv32m zicsr_trap pipeline memory perf_micro
TEST ?= rv32i

ARCH_FLAGS := -march=rv32im_zicsr -mabi=ilp32
ASFLAGS := $(ARCH_FLAGS) -mno-relax -nostdlib -nostartfiles -static \
	-Wl,--no-relax -Wl,--build-id=none -T linker.ld -Itests

.SECONDARY:

.PHONY: all clean list check run regression competition fetch-open-source \
	verify-open-source build-open-source run-open-source

all: $(TESTS:%=$(BUILD)/%.irom.coe) $(TESTS:%=$(BUILD)/%.bram.coe)

list:
	@printf '%s\n' $(TESTS)

$(BUILD):
	@mkdir -p $@

$(BUILD)/%.elf: tests/%.S tests/common.S linker.ld | $(BUILD)
	$(CC) $(ASFLAGS) -o $@ $<
	python3 tools/validate_elf.py --objdump $(OBJDUMP) $@
	$(OBJDUMP) -d -M no-aliases,numeric $@ > $(BUILD)/$*.dump

$(BUILD)/%.irom.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary --only-section=.text $< $@

$(BUILD)/%.bram.bin: $(BUILD)/%.elf
	$(OBJCOPY) -O binary --only-section=.data $< $@

$(BUILD)/%.irom.coe: $(BUILD)/%.irom.bin tools/bin_to_coe.py
	python3 tools/bin_to_coe.py --max-words 4096 $< $@

$(BUILD)/%.bram.coe: $(BUILD)/%.bram.bin tools/bin_to_coe.py
	python3 tools/bin_to_coe.py --max-words 65536 $< $@

check: all
	python3 tools/check_manifest.py upstream.lock.json

run: $(BUILD)/$(TEST).irom.coe $(BUILD)/$(TEST).bram.coe
	python3 tools/run_regression.py --root $(ROOT) --test $(TEST)

regression: all
	python3 tools/run_regression.py --root $(ROOT) $(TESTS:%=--test %)

competition:
	python3 tools/run_competition.py --root $(ROOT)

fetch-open-source:
	python3 tools/fetch_upstream.py --lock upstream.lock.json --dest third_party

verify-open-source:
	python3 tools/check_manifest.py upstream.lock.json --sources third_party

build-open-source:
	python3 tools/build_riscv_tests.py --root $(ROOT) --sources third_party \
		--lock upstream.lock.json --output $(BUILD)/riscv-tests

run-open-source: build-open-source
	python3 tools/run_riscv_tests.py --root $(ROOT) --build $(BUILD)/riscv-tests

clean:
	rm -rf $(BUILD)
