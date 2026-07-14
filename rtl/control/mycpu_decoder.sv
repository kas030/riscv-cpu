`include "../common/defines.sv"

// =============================================================================
// mycpu_decoder.sv
//   ID-stage decoder facade. It groups main control, immediate generation, ALU
//   decode and CSR/system decode behind one boundary.
// =============================================================================
module mycpu_decoder #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] ID_instr,

    output logic [DATAWIDTH - 1:0] ID_imm,
    output logic                   ID_RegWrite,
    output logic                   ID_MemWrite,
    output logic                   ID_MemRead,
    output logic                   ID_ALUSrcA,
    output logic                   ID_ALUSrcB,
    output logic [2:0]             ID_MemToReg,
    output logic [1:0]             ID_NpcOp,
    output logic [1:0]             ID_OffsetOrigin,
    output logic [`ALU_OP_WIDTH - 1:0] ID_ALUControl,
    output logic [11:0]            ID_csr_idx,
    output logic [4:0]             ID_csr_zimm,
    output logic [5:0]             ID_CSRControll,
    output logic [2:0]             ID_funct3,
    output logic [4:0]             ID_rs1,
    output logic [4:0]             ID_rs2,
    output logic [4:0]             ID_rd
);
    assign ID_rs1    = ID_instr[19:15];
    assign ID_rs2    = ID_instr[24:20];
    assign ID_rd     = ID_instr[11: 7];
    assign ID_funct3 = ID_instr[14:12];

    main_ctrl u_main_ctrl (
        .instr        (ID_instr       ),
        .NpcOp        (ID_NpcOp       ),
        .RegWrite     (ID_RegWrite    ),
        .MemToReg     (ID_MemToReg    ),
        .MemWrite     (ID_MemWrite    ),
        .MemRead      (ID_MemRead     ),
        .OffsetOrigin (ID_OffsetOrigin),
        .ALUSrcA      (ID_ALUSrcA     ),
        .ALUSrcB      (ID_ALUSrcB     )
    );

    imm_gen #(DATAWIDTH) u_imm_gen (
        .instr (ID_instr),
        .imm   (ID_imm  )
    );

    alu_ctrl u_alu_ctrl (
        .instr      (ID_instr     ),
        .ALUControl (ID_ALUControl)
    );

    csr_ctrl_decode u_csr_ctrl_decode (
        .instr       (ID_instr      ),
        .csr_idx     (ID_csr_idx    ),
        .csr_zimm    (ID_csr_zimm   ),
        .CSRControll (ID_CSRControll)
    );
endmodule
