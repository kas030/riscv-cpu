// =============================================================================
// mycpu_pipeline_ctrl.sv
//   Small pipeline controller inspired by the controller boundary used in Ibex.
//   It keeps stall/flush/BHT-update policy out of the top-level wiring.
// =============================================================================
module mycpu_pipeline_ctrl (
    input  logic       stall_hazard_i,
    input  logic       ex_busy_i,
    input  logic       flush_id_ex_hazard_i,
    input  logic [1:0] ex_npc_op_i,
    input  logic       branch_taken_i,

    output logic       stall_front_o,
    output logic       flush_id_ex_o,
    output logic       bp_update_en_o,
    output logic       bp_update_taken_o
);
    assign stall_front_o     = stall_hazard_i | ex_busy_i;
    assign flush_id_ex_o     = flush_id_ex_hazard_i & ~ex_busy_i;
    assign bp_update_en_o    = !ex_busy_i && (ex_npc_op_i == 2'b01);
    assign bp_update_taken_o = branch_taken_i;
endmodule
