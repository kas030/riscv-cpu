`timescale 1ns / 1ps

module myCPU_id_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] ID_instr,
    output logic [DATAWIDTH - 1:0] ID_imm,
    output logic                   ID_RegWrite,
    output logic                   ID_MemWrite,
    output logic                   ID_MemRead,
    output logic                   ID_isCSR,
    output logic                   ID_ALUSrcA,
    output logic                   ID_ALUSrcB,
    output logic [2:0]             ID_MemToReg,
    output logic [1:0]             ID_NpcOp,
    output logic [1:0]             ID_OffsetOrigin,
    output logic [13:0]            ID_ALUControl,
    output logic [11:0]            ID_csr_idx,
    output logic [3:0]             ID_CSRControll,
    output logic [2:0]             ID_funct3,
    output logic [4:0]             ID_rs1,
    output logic [4:0]             ID_rs2,
    output logic [4:0]             ID_rd
);
    assign ID_rs1    = ID_instr[19:15];
    assign ID_rs2    = ID_instr[24:20];
    assign ID_rd     = ID_instr[11:7];
    assign ID_funct3 = ID_instr[14:12];

    Control control_inst (
        .opcode       (ID_instr[6:0]),
        .funct        (ID_funct3),
        .NpcOp        (ID_NpcOp),
        .RegWrite     (ID_RegWrite),
        .MemToReg     (ID_MemToReg),
        .MemWrite     (ID_MemWrite),
        .MemRead      (ID_MemRead),
        .OffsetOrigin (ID_OffsetOrigin),
        .ALUSrcA      (ID_ALUSrcA),
        .ALUSrcB      (ID_ALUSrcB),
        .isCSR        (ID_isCSR)
    );

    IMMGEN #(DATAWIDTH) immgen_inst (
        .instr (ID_instr),
        .imm   (ID_imm)
    );

    ACTL actl_inst (
        .opcode     (ID_instr[6:0]),
        .funct      ({ID_instr[30], ID_funct3}),
        .ALUControl (ID_ALUControl)
    );

    CCTL cctl_inst (
        .instr       (ID_instr),
        .csr_idx     (ID_csr_idx),
        .CSRControll (ID_CSRControll)
    );
endmodule
