`timescale 1ns / 1ps
`include "../../common/defines.sv"

// =============================================================================
// mycpu_ex_stage.sv
//   EX stage: forwarding select, ALU, RV32M unit, CSR file and PC redirect.
// =============================================================================
module mycpu_ex_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] MEM_forward_data,
    input  logic [DATAWIDTH - 1:0] WB_wdata,
    input  logic [DATAWIDTH - 1:0] EX_pc,
    input  logic [DATAWIDTH - 1:0] EX_imm,
    input  logic [DATAWIDTH - 1:0] EX_rR1_data,
    input  logic [DATAWIDTH - 1:0] EX_rR2_data,
    input  logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl,
    input  logic [1:0]             EX_NpcOp,
    input  logic [1:0]             EX_OffsetOrigin,
    input  logic [11:0]            EX_csr_idx,
    input  logic [4:0]             EX_csr_zimm,
    input  logic [5:0]             EX_CSRControll,
    input  logic [1:0]             ForwardA,
    input  logic [1:0]             ForwardB,
    input  logic                   EX_ALUSrcA,
    input  logic                   EX_ALUSrcB,
    input  logic                   EX_pred_taken,
    input  logic [DATAWIDTH - 1:0] EX_pred_target,
    input  logic                   clk,
    input  logic                   rst,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect,
    output logic [DATAWIDTH - 1:0] EX_alu_result,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out,
    output logic [DATAWIDTH - 1:0] EX_csr_wb,
    output logic                   BranchTaken,
    output logic                   BranchMispredict,
    output logic                   EX_busy
);
    logic [DATAWIDTH - 1:0] alu_in_a, alu_in_b;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] npc_offset;
    logic [DATAWIDTH - 1:0] jalr_target;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic [DATAWIDTH - 1:0] csr_wdata;
    logic [DATAWIDTH - 1:0] alu_result_i;
    logic [DATAWIDTH - 1:0] m_result;
    logic                   alu_isTrue;
    logic                   is_m_op;
    logic                   m_busy, m_done, m_start;

    assign EX_forward_A_out = (ForwardA == 2'b10) ? MEM_forward_data :
                              (ForwardA == 2'b01) ? WB_wdata         :
                                                    EX_rR1_data;
    assign EX_forward_B_out = (ForwardB == 2'b10) ? MEM_forward_data :
                              (ForwardB == 2'b01) ? WB_wdata         :
                                                    EX_rR2_data;

    assign alu_in_a = EX_ALUSrcA ? EX_pc  : EX_forward_A_out;
    assign alu_in_b = EX_ALUSrcB ? EX_imm : EX_forward_B_out;
    assign is_m_op  = |EX_ALUControl[21:14];

    alu #(DATAWIDTH) u_alu (
        .A          (alu_in_a     ),
        .B          (alu_in_b     ),
        .ALUControl (EX_ALUControl),
        .Result     (alu_result_i ),
        .isTrue     (alu_isTrue   )
    );

    assign m_start = is_m_op && !m_busy && !m_done;

    rv32m_unit #(DATAWIDTH) u_rv32m_unit (
        .clk         (clk          ),
        .rst         (rst          ),
        .start       (m_start      ),
        .alu_control (EX_ALUControl),
        .operand_a   (alu_in_a     ),
        .operand_b   (alu_in_b     ),
        .busy        (m_busy       ),
        .done        (m_done       ),
        .result      (m_result     )
    );

    assign EX_busy       = is_m_op && !m_done;
    assign EX_alu_result = is_m_op ? m_result : alu_result_i;
    assign csr_wdata     = EX_CSRControll[5] ? {{(DATAWIDTH-5){1'b0}}, EX_csr_zimm} :
                                               EX_forward_A_out;

    csr_file #(DATAWIDTH) u_csr_file (
        .clk         (clk           ),
        .rst         (rst           ),
        .pc          (EX_pc         ),
        .csr_wdata   (csr_wdata     ),
        .csr_idx     (EX_csr_idx    ),
        .CSRControll (EX_CSRControll),
        .csr_npc     (csr_npc       ),
        .csr_wb      (EX_csr_wb     )
    );

    assign jalr_target = (EX_forward_A_out + EX_imm) & {{DATAWIDTH - 1{1'b1}}, 1'b0};
    assign npc_offset  = {DATAWIDTH{EX_OffsetOrigin == 2'b00}} & EX_imm      |
                         {DATAWIDTH{EX_OffsetOrigin == 2'b01}} & jalr_target |
                         {DATAWIDTH{EX_OffsetOrigin == 2'b10}} & csr_npc;

    npc_calc #(DATAWIDTH) u_npc_calc (
        .isTrue (alu_isTrue     ),
        .npc_op (EX_NpcOp       ),
        .pc     (EX_pc          ),
        .offset (npc_offset     ),
        .npc    (IF_npc_redirect),
        .pcadd4 (               )
    );

    mycpu_redirect_ctrl #(DATAWIDTH) u_redirect_ctrl (
        .ex_busy_i           (EX_busy         ),
        .ex_npc_op_i         (EX_NpcOp        ),
        .ex_pc_i             (EX_pc           ),
        .alu_branch_true_i   (alu_isTrue      ),
        .redirect_pc_i       (IF_npc_redirect ),
        .pred_taken_i        (EX_pred_taken   ),
        .pred_target_i       (EX_pred_target  ),
        .branch_taken_o      (BranchTaken     ),
        .branch_mispredict_o (BranchMispredict)
    );
endmodule
