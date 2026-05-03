`timescale 1ns / 1ps

module myCPU_ex_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] MEM_forward_data,
    input  logic [DATAWIDTH - 1:0] WB_wdata,
    input  logic [DATAWIDTH - 1:0] EX_pc,
    input  logic [DATAWIDTH - 1:0] EX_imm,
    input  logic [DATAWIDTH - 1:0] EX_rR1_data,
    input  logic [DATAWIDTH - 1:0] EX_rR2_data,
    input  logic [13:0]            EX_ALUControl,
    input  logic [1:0]             EX_NpcOp,
    input  logic [1:0]             EX_OffsetOrigin,
    input  logic [11:0]            EX_csr_idx,
    input  logic [3:0]             EX_CSRControll,
    input  logic [1:0]             ForwardA,
    input  logic [1:0]             ForwardB,
    input  logic                   EX_ALUSrcA,
    input  logic                   EX_ALUSrcB,
    input  logic                   clk,
    input  logic                   rst,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect,
    output logic [DATAWIDTH - 1:0] EX_alu_result,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out,
    output logic [DATAWIDTH - 1:0] EX_csr_wb,
    output logic                   BranchTaken
);
    logic [DATAWIDTH - 1:0] EX_alu_A, EX_alu_B;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] EX_offset;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic                   EX_isTrue;

    assign EX_forward_A_out = (ForwardA == 2'b10) ? MEM_forward_data :
                              (ForwardA == 2'b01) ? WB_wdata : EX_rR1_data;
    assign EX_forward_B_out = (ForwardB == 2'b10) ? MEM_forward_data :
                              (ForwardB == 2'b01) ? WB_wdata : EX_rR2_data;

    assign EX_alu_A = EX_ALUSrcA ? EX_pc : EX_forward_A_out;
    assign EX_alu_B = EX_ALUSrcB ? EX_imm : EX_forward_B_out;

    ALU #(DATAWIDTH) alu_inst (
        .A          (EX_alu_A),
        .B          (EX_alu_B),
        .ALUControl (EX_ALUControl),
        .Result     (EX_alu_result),
        .isTrue     (EX_isTrue)
    );

    CSR #(DATAWIDTH) csr_inst (
        .clk         (clk),
        .rst         (rst),
        .pc          (EX_pc),
        .rf1         (EX_forward_A_out),
        .csr_idx     (EX_csr_idx),
        .CSRControll (EX_CSRControll),
        .csr_npc     (csr_npc),
        .csr_wb      (EX_csr_wb)
    );

    assign EX_offset = {DATAWIDTH{EX_OffsetOrigin == 2'b00}} & EX_imm |
                       {DATAWIDTH{EX_OffsetOrigin == 2'b01}} & EX_alu_result |
                       {DATAWIDTH{EX_OffsetOrigin == 2'b10}} & csr_npc;

    NPC #(DATAWIDTH) npc_inst (
        .isTrue (EX_isTrue),
        .npc_op (EX_NpcOp),
        .pc     (EX_pc),
        .offset (EX_offset),
        .npc    (IF_npc_redirect),
        .pcadd4 ()
    );

    assign BranchTaken = (EX_NpcOp == 2'b01 && EX_isTrue) ||
                         (EX_NpcOp == 2'b10) ||
                         (EX_NpcOp == 2'b11);
endmodule
