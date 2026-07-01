`include "../common/defines.sv"

// =============================================================================
// main_ctrl.sv - Main instruction control decode
// =============================================================================
module main_ctrl(
    input  logic [31:0] instr,
    output logic [1:0]  NpcOp,
    output logic        RegWrite,
    output logic [2:0]  MemToReg,
    output logic        MemWrite,
    output logic        MemRead,
    output logic [1:0]  OffsetOrigin,
    output logic        ALUSrcA,
    output logic        ALUSrcB
);
    logic [6:0] opcode = instr[6:0];
    logic [2:0] funct  = instr[14:12];
    logic is_jalr, is_branch, is_jal, is_store, is_rtype, is_itype;
    logic is_load, is_auipc, is_lui, is_csr, is_ecall, is_mret, is_callret;

    assign is_jalr    = (opcode == `IJ_TYPE);
    assign is_branch  = (opcode == `B_TYPE);
    assign is_jal     = (opcode == `J_TYPE);
    assign is_store   = (opcode == `S_TYPE);
    assign is_rtype   = (opcode == `R_TYPE);
    assign is_itype   = (opcode == `I_TYPE);
    assign is_load    = (opcode == `IL_TYPE);
    assign is_auipc   = (opcode == `UA_TYPE);
    assign is_lui     = (opcode == `U_TYPE);
    assign is_csr     = (opcode == `CSR_TYPE) &&
                        ((funct == 3'b001) || (funct == 3'b010) || (funct == 3'b011) ||
                         (funct == 3'b101) || (funct == 3'b110) || (funct == 3'b111));
    assign is_ecall   = (instr == 32'h0000_0073);
    assign is_mret    = (instr == 32'h3020_0073);
    assign is_callret = is_ecall || is_mret;

    // 00 sequential, 01 conditional branch, 10 absolute target, 11 jal.
    assign NpcOp        = {2{is_jalr   }} & 2'b10 |
                          {2{is_callret}} & 2'b10 |
                          {2{is_branch }} & 2'b01 |
                          {2{is_jal    }} & 2'b11;

    assign RegWrite     = ~(is_branch | is_store | is_callret);

    assign MemToReg     = {3{is_rtype}} & 3'b001 |
                          {3{is_itype}} & 3'b001 |
                          {3{is_auipc}} & 3'b001 |
                          {3{is_load }} & 3'b010 |
                          {3{is_lui  }} & 3'b011 |
                          {3{is_csr  }} & 3'b100;

    assign MemWrite     = is_store;
    assign OffsetOrigin = {2{is_jalr   }} & 2'b01 |
                          {2{is_callret}} & 2'b10;
    assign ALUSrcA      = is_auipc;
    assign ALUSrcB      = ~(is_rtype | is_branch);
    assign MemRead      = is_load;
endmodule
