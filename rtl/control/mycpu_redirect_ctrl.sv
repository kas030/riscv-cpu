// =============================================================================
// mycpu_redirect_ctrl.sv
//   Centralizes control-flow redirect decisions. The EX stage still computes
//   the real target; this block decides whether the front-end prediction was
//   correct and whether IF/ID and ID/EX must be flushed.
// =============================================================================
module mycpu_redirect_ctrl #(
    parameter DATAWIDTH = 32
) (
    input  logic                   ex_busy_i,
    input  logic [1:0]             ex_npc_op_i,
    input  logic [DATAWIDTH-1:0]   ex_pc_i,
    input  logic                   alu_branch_true_i,
    input  logic [DATAWIDTH-1:0]   redirect_pc_i,
    input  logic                   pred_taken_i,
    input  logic [DATAWIDTH-1:0]   pred_target_i,

    output logic                   branch_taken_o,
    output logic                   branch_mispredict_o
);
    logic [DATAWIDTH-1:0] predicted_next_pc;
    logic                 is_control_flow;

    assign branch_taken_o = !ex_busy_i && (
                            (ex_npc_op_i == 2'b01 && alu_branch_true_i) ||
                            (ex_npc_op_i == 2'b10                    ) ||
                            (ex_npc_op_i == 2'b11                    ));

    assign is_control_flow     = (ex_npc_op_i != 2'b00);
    assign predicted_next_pc   = pred_taken_i ? pred_target_i : (ex_pc_i + 4);
    assign branch_mispredict_o = !ex_busy_i && is_control_flow &&
                                 (redirect_pc_i != predicted_next_pc);
endmodule
