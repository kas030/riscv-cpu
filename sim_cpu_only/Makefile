ROOT := ..
VERILATOR ?= verilator
CXX ?= g++
IVERILOG ?= iverilog
VVP ?= vvp

BUILD := build
SRC_COMMON := $(ROOT)/rtl/common
SRC_CONTROL := $(ROOT)/rtl/control
SRC_CORE := $(ROOT)/rtl/core
SRC_DATAPATH := $(ROOT)/rtl/datapath
SRC_HAZARD := $(ROOT)/rtl/hazard
SRC_MEMORY := $(ROOT)/rtl/memory
SRC_PIPE_REG := $(ROOT)/rtl/pipeline/register
SRC_PIPE_STAGE := $(ROOT)/rtl/pipeline/stage
IROM_COE := $(ROOT)/sim/coe/mext/irom-v2.coe
BRAM_COE := $(ROOT)/sim/coe/mext/dram.coe
EXPECTED_LED ?=
PASS_LED ?= 01221C08
FAIL_LED ?= 24181824
TRACE ?= 0
TRACE_FILE ?= $(BUILD)/wave.fst
CPU_FREQ_MHZ ?= 200.0
STOP_NS ?= 400000000
PROGRESS_NS ?= 10000000
QUIET ?= 1
VERILATOR_RUNTIME_ARGS ?=

-include config.mk

VERILATOR_QUIET_CANDIDATES := --quiet --quiet-build --quiet-exit
VERILATOR_QUIET_FLAGS := $(if $(filter 1,$(QUIET)),$(shell for flag in $(VERILATOR_QUIET_CANDIDATES); do $(VERILATOR) $$flag --version >/dev/null 2>&1 && printf '%s ' $$flag; done),)
VFLAGS_BASE := --binary --timing $(VERILATOR_QUIET_FLAGS) -MAKEFLAGS -s -CFLAGS -DVL_USER_FINISH -Wno-fatal -Wno-TIMESCALEMOD -Wno-WIDTH -Wno-UNOPTFLAT -Wno-ZERODLY -Wno-UNSIGNED
VFLAGS_TRACE := $(if $(filter 1,$(TRACE)),--trace-fst --trace-structs -LDFLAGS -lz,)
VFLAGS := $(VFLAGS_BASE) $(VFLAGS_TRACE)
VERILATOR_OBJ_DIR := $(if $(filter 1,$(TRACE)),obj_dir_trace,obj_dir)
INC_DIRS := -I$(SRC_COMMON) -I$(SRC_CONTROL) -I$(SRC_CORE) -I$(SRC_DATAPATH) -I$(SRC_HAZARD) -I$(SRC_MEMORY) -I$(SRC_PIPE_REG) -I$(SRC_PIPE_STAGE) -I$(BUILD)

CPU_SRCS := \
  $(SRC_COMMON)/mux_key_internal.v \
  $(SRC_COMMON)/mux_key.v \
  $(SRC_COMMON)/defines.sv \
  $(SRC_CONTROL)/alu_ctrl.sv \
  $(SRC_CONTROL)/csr_ctrl_decode.sv \
  $(SRC_CONTROL)/csr_file.sv \
  $(SRC_CONTROL)/main_ctrl.sv \
  $(SRC_CONTROL)/imm_gen.sv \
  $(SRC_CONTROL)/npc_calc.sv \
  $(SRC_CONTROL)/mycpu_decoder.sv \
  $(SRC_CONTROL)/mycpu_redirect_ctrl.sv \
  $(SRC_CORE)/mycpu.sv \
  $(SRC_DATAPATH)/alu.sv \
  $(SRC_DATAPATH)/pc_reg.sv \
  $(SRC_DATAPATH)/reg_file.sv \
  $(SRC_DATAPATH)/rv32m_unit.sv \
  $(SRC_HAZARD)/forwarding_unit.sv \
  $(SRC_HAZARD)/hazard_unit.sv \
  $(SRC_MEMORY)/load_l0_cache.sv \
  $(SRC_MEMORY)/load_mask.sv \
  $(SRC_MEMORY)/mycpu_lsu.sv \
  $(SRC_PIPE_REG)/mycpu_if_id_reg.sv \
  $(SRC_PIPE_REG)/mycpu_id_ex_reg.sv \
  $(SRC_PIPE_REG)/mycpu_ex_mem_reg.sv \
  $(SRC_PIPE_REG)/mycpu_mem1_mem2_reg.sv \
  $(SRC_PIPE_REG)/mycpu_mem_wb_reg.sv \
  $(SRC_PIPE_STAGE)/mycpu_if_stage.sv \
  $(SRC_PIPE_STAGE)/mycpu_id_stage.sv \
  $(SRC_PIPE_STAGE)/mycpu_ex_stage.sv \
  $(SRC_PIPE_STAGE)/mycpu_mem_stage.sv \
  $(SRC_PIPE_STAGE)/mycpu_wb_stage.sv

.PHONY: all sim sim-iverilog sim-verilator clean check-tools check-verilator FORCE

all: sim-verilator

check-tools:
	@$(IVERILOG) -V >/dev/null
	@$(VVP) -V >/dev/null 2>&1

check-verilator:
	@$(VERILATOR) --version >/dev/null
	@$(CXX) --version >/dev/null

$(BUILD):
	@mkdir -p $@

$(BUILD)/sim_config.svh: sim_config_gen.py FORCE | $(BUILD)
	@EXPECTED_LED="$(EXPECTED_LED)" PASS_LED="$(PASS_LED)" FAIL_LED="$(FAIL_LED)" TRACE="$(TRACE)" CPU_FREQ_MHZ="$(CPU_FREQ_MHZ)" STOP_NS="$(STOP_NS)" PROGRESS_NS="$(PROGRESS_NS)" TRACE_FILE="$(TRACE_FILE)" \
	python3 sim_config_gen.py $@

$(BUILD)/irom.mem: $(IROM_COE) coe_to_mem.py FORCE | $(BUILD)
	@python3 coe_to_mem.py $(IROM_COE) $@

$(BUILD)/bram.mem: $(BRAM_COE) coe_to_mem.py FORCE | $(BUILD)
	@python3 coe_to_mem.py $(BRAM_COE) $@

$(BUILD)/tb_cpu_only.vvp: tb_cpu_only.sv $(CPU_SRCS) $(BUILD)/sim_config.svh | $(BUILD)
	@$(IVERILOG) -g2012 -Wall $(INC_DIRS) -s tb_cpu_only -o $@ $^

sim: sim-verilator

sim-iverilog: check-tools $(BUILD)/irom.mem $(BUILD)/bram.mem $(BUILD)/tb_cpu_only.vvp
	@stdbuf -oL -eL $(VVP) $(BUILD)/tb_cpu_only.vvp | tee $(BUILD)/sim.log

$(VERILATOR_OBJ_DIR)/Vtb_cpu_only: tb_cpu_only.sv verilator_finish_quiet.cpp $(CPU_SRCS) $(BUILD)/sim_config.svh | $(BUILD)
	@CXX=$(CXX) $(VERILATOR) $(VFLAGS) --Mdir $(VERILATOR_OBJ_DIR) $(INC_DIRS) --top-module tb_cpu_only $^

sim-verilator: check-verilator $(BUILD)/irom.mem $(BUILD)/bram.mem $(VERILATOR_OBJ_DIR)/Vtb_cpu_only
	@stdbuf -oL -eL ./$(VERILATOR_OBJ_DIR)/Vtb_cpu_only $(VERILATOR_RUNTIME_ARGS) | tee $(BUILD)/verilator-sim.log

clean:
	@rm -rf $(BUILD) obj_dir obj_dir_trace
