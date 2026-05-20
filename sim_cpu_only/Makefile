ROOT := ..
MAMBA ?= /home/mph/.local/bin/micromamba
MAMBA_ROOT ?= /home/mph/.local/micromamba
ENV ?= hdl
RUN := $(MAMBA) run -r $(MAMBA_ROOT) -n $(ENV)
ENV_PREFIX := $(MAMBA_ROOT)/envs/$(ENV)
ENV_BIN := $(ENV_PREFIX)/bin
VERILATOR := $(ENV_BIN)/verilator
CXX := $(ENV_BIN)/x86_64-conda-linux-gnu-g++

BUILD := build
SRC_COMMON := $(ROOT)/rtl/common
SRC_CONTROL := $(ROOT)/rtl/control
SRC_CORE := $(ROOT)/rtl/core
SRC_DATAPATH := $(ROOT)/rtl/datapath
SRC_HAZARD := $(ROOT)/rtl/hazard
SRC_MEMORY := $(ROOT)/rtl/memory
SRC_PIPE_REG := $(ROOT)/rtl/pipeline/register
SRC_PIPE_STAGE := $(ROOT)/rtl/pipeline/stage
IROM_COE := $(ROOT)/sim/coe/irom.coe
DRAM_COE := $(ROOT)/sim/coe/dram.coe
EXPECTED_LED ?=
TRACE ?= 0
TRACE_FILE ?= $(BUILD)/wave.fst
STOP_NS ?= 400000000
PROGRESS_NS ?= 10000000

-include config.mk

VFLAGS_BASE := --binary --timing --quiet --quiet-build -MAKEFLAGS -s -CFLAGS -DVL_USER_FINISH -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTH -Wno-UNOPTFLAT -Wno-ZERODLY -Wno-UNSIGNED
VFLAGS_TRACE := $(if $(filter 1,$(TRACE)),--trace-fst --trace-structs -CFLAGS -I$(ENV_PREFIX)/include -LDFLAGS -L$(ENV_PREFIX)/lib -LDFLAGS -lz,)
VFLAGS := $(VFLAGS_BASE) $(VFLAGS_TRACE)
VERILATOR_OBJ_DIR := $(if $(filter 1,$(TRACE)),obj_dir_trace,obj_dir)
INC_DIRS := -I$(SRC_COMMON) -I$(SRC_CONTROL) -I$(SRC_CORE) -I$(SRC_DATAPATH) -I$(SRC_HAZARD) -I$(SRC_MEMORY) -I$(SRC_PIPE_REG) -I$(SRC_PIPE_STAGE) -I$(BUILD)

CPU_SRCS := \
  $(SRC_COMMON)/MuxKeyInternal.v \
  $(SRC_COMMON)/MuxKey.v \
  $(SRC_COMMON)/defines.sv \
  $(SRC_CONTROL)/ACTL.sv \
  $(SRC_CONTROL)/CCTL.sv \
  $(SRC_CONTROL)/CSR.sv \
  $(SRC_CONTROL)/Control.sv \
  $(SRC_CONTROL)/IMMGEN.sv \
  $(SRC_CONTROL)/NPC.sv \
  $(SRC_CORE)/myCPU.sv \
  $(SRC_DATAPATH)/ALU.sv \
  $(SRC_DATAPATH)/PC.sv \
  $(SRC_DATAPATH)/RF.sv \
  $(SRC_HAZARD)/ForwardingUnit.sv \
  $(SRC_HAZARD)/HazardUnit.sv \
  $(SRC_MEMORY)/Mask.sv \
  $(SRC_PIPE_REG)/myCPU_if_id_reg.sv \
  $(SRC_PIPE_REG)/myCPU_id_ex_reg.sv \
  $(SRC_PIPE_REG)/myCPU_ex_mem_reg.sv \
  $(SRC_PIPE_REG)/myCPU_mem_wb_reg.sv \
  $(SRC_PIPE_STAGE)/myCPU_if_stage.sv \
  $(SRC_PIPE_STAGE)/myCPU_id_stage.sv \
  $(SRC_PIPE_STAGE)/myCPU_ex_stage.sv \
  $(SRC_PIPE_STAGE)/myCPU_mem_stage.sv \
  $(SRC_PIPE_STAGE)/myCPU_wb_stage.sv

.PHONY: all sim sim-iverilog sim-verilator clean check-tools check-verilator FORCE

all: sim-verilator

check-tools:
	@$(RUN) iverilog -V >/dev/null
	@$(RUN) vvp -V >/dev/null 2>&1

check-verilator:
	@$(VERILATOR) --version >/dev/null
	@$(CXX) --version >/dev/null

$(BUILD):
	@mkdir -p $@

$(BUILD)/sim_config.svh: sim_config_gen.py FORCE | $(BUILD)
	@EXPECTED_LED="$(EXPECTED_LED)" TRACE="$(TRACE)" STOP_NS="$(STOP_NS)" PROGRESS_NS="$(PROGRESS_NS)" TRACE_FILE="$(TRACE_FILE)" \
	python3 sim_config_gen.py $@

$(BUILD)/irom.mem: $(IROM_COE) coe_to_mem.py FORCE | $(BUILD)
	@python3 coe_to_mem.py $(IROM_COE) $@

$(BUILD)/dram.mem: $(DRAM_COE) coe_to_mem.py FORCE | $(BUILD)
	@python3 coe_to_mem.py $(DRAM_COE) $@

$(BUILD)/tb_cpu_only.vvp: tb_cpu_only.sv $(CPU_SRCS) $(BUILD)/sim_config.svh | $(BUILD)
	@$(RUN) iverilog -g2012 -Wall $(INC_DIRS) -s tb_cpu_only -o $@ $^

sim: sim-verilator

sim-iverilog: check-tools $(BUILD)/irom.mem $(BUILD)/dram.mem $(BUILD)/tb_cpu_only.vvp
	@stdbuf -oL -eL $(RUN) vvp $(BUILD)/tb_cpu_only.vvp | tee $(BUILD)/sim.log

$(VERILATOR_OBJ_DIR)/Vtb_cpu_only: tb_cpu_only.sv verilator_finish_quiet.cpp $(CPU_SRCS) $(BUILD)/sim_config.svh | $(BUILD)
	@PATH=$(ENV_BIN):$$PATH CXX=$(CXX) $(VERILATOR) $(VFLAGS) --Mdir $(VERILATOR_OBJ_DIR) $(INC_DIRS) --top-module tb_cpu_only $^

sim-verilator: check-verilator $(BUILD)/irom.mem $(BUILD)/dram.mem $(VERILATOR_OBJ_DIR)/Vtb_cpu_only
	@stdbuf -oL -eL ./$(VERILATOR_OBJ_DIR)/Vtb_cpu_only +verilator+quiet | tee $(BUILD)/verilator-sim.log

clean:
	@rm -rf $(BUILD) obj_dir obj_dir_trace
