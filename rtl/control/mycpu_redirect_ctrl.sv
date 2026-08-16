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
    input  logic                   alu_branch_true_i,
    input  logic [DATAWIDTH-1:0]   jalr_csr_target_i,
    input  logic                   pred_taken_i,
    input  logic [DATAWIDTH-1:0]   pred_target_i,

    output logic                   branch_taken_o,
    output logic                   branch_mispredict_o
);
    logic is_branch;
    logic is_jalr_csr;
    logic is_jal;
    logic branch_mispredict;
    logic jal_mispredict;
    logic jalr_csr_mispredict;

    assign is_branch   = (ex_npc_op_i == 2'b01);
    assign is_jalr_csr = (ex_npc_op_i == 2'b10);
    assign is_jal      = (ex_npc_op_i == 2'b11);

    assign branch_taken_o = !ex_busy_i &&
                            ((is_branch && alu_branch_true_i) ||
                             is_jalr_csr ||
                             is_jal);

    // BTB tag 覆盖项目 IROM 的完整字地址，且 branch/jal 的 PC-relative
    // 目标在只读 IROM 中恒定。命中后的目标必然正确，只需检查方向；
    // jalr/CSR 目标可变，仍保留完整目标比较。
    assign branch_mispredict = is_branch &&
                               (pred_taken_i != alu_branch_true_i);
    assign jal_mispredict = is_jal && !pred_taken_i;
    assign jalr_csr_mispredict = is_jalr_csr &&
                                 (!pred_taken_i || (pred_target_i != jalr_csr_target_i));

    assign branch_mispredict_o = !ex_busy_i &&
                                 (branch_mispredict ||
                                  jal_mispredict ||
                                  jalr_csr_mispredict);
endmodule
