VISUAL_TRACE_OUT ?= $(abspath $(BUILD)/visual-trace.raw.jsonl)
VISUAL_OBJ_DIR ?= obj_dir_visual
VISUAL_SIM_LOG ?= $(BUILD)/visual-trace-sim.log
VISUAL_DISABLED_LOG ?= $(BUILD)/visual-trace-disabled-sim.log

.PHONY: visual-trace visual-trace-disabled

$(VISUAL_OBJ_DIR)/Vtb_visual_trace: tb_cpu_only.sv tb_visual_trace.sv visual_trace_probe.sv verilator_finish_quiet.cpp $(CPU_SRCS) $(BUILD)/sim_config.svh | $(BUILD)
	@CXX=$(CXX) $(VERILATOR) $(VFLAGS_BASE) --Mdir $(VISUAL_OBJ_DIR) $(INC_DIRS) --top-module tb_visual_trace $^

visual-trace: check-verilator $(BUILD)/irom.mem $(BUILD)/bram.mem $(VISUAL_OBJ_DIR)/Vtb_visual_trace
	@stdbuf -oL -eL ./$(VISUAL_OBJ_DIR)/Vtb_visual_trace +visual_trace=$(VISUAL_TRACE_OUT) $(VERILATOR_RUNTIME_ARGS) | tee $(VISUAL_SIM_LOG)

visual-trace-disabled: check-verilator $(BUILD)/irom.mem $(BUILD)/bram.mem $(VERILATOR_OBJ_DIR)/Vtb_cpu_only
	@stdbuf -oL -eL ./$(VERILATOR_OBJ_DIR)/Vtb_cpu_only $(VERILATOR_RUNTIME_ARGS) | tee $(VISUAL_DISABLED_LOG)
