// =============================================================================
// alu_ctrl.sv —— alu 控制译码
//   位于 ID 级，从完整指令中提取 opcode/funct7/funct3 并译码独热 ALUControl，
//   每一位对应 alu 的一种运算（RV32I 算术逻辑/比较 + RV32M 乘除余）。
//   一热编码使得 alu 内部可以用按位与 + 或汇总，避免使用 case，
//   有利于布局布线时分散到多 LUT 上从而缩短关键路径。
// =============================================================================
`include "../common/defines.sv"

module alu_ctrl(
    input  logic [31:0]                   instr     ,      // 完整指令，便于严格匹配扩展编码
    output logic [`ALU_OP_WIDTH - 1:0]   ALUControl        // 独热 alu 操作码
);
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_ADD    = 22'h000001;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_SUB    = 22'h000002;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_AND    = 22'h000004;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_OR     = 22'h000008;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_XOR    = 22'h000010;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_SLL    = 22'h000020;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_SRL    = 22'h000040;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_SRA    = 22'h000080;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BEQ    = 22'h000100;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BNE    = 22'h000200;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BLT    = 22'h000400;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BGE    = 22'h000800;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BGEU   = 22'h001000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_BLTU   = 22'h002000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_MUL    = 22'h004000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_MULH   = 22'h008000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_MULHSU = 22'h010000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_MULHU  = 22'h020000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_DIV    = 22'h040000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_DIVU   = 22'h080000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_REM    = 22'h100000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_REMU   = 22'h200000;
    localparam logic [`ALU_OP_WIDTH - 1:0] OP_CTZ = 23'h400000;

    logic do_add , do_sub , do_and , do_or  , do_xor , do_sll , do_srl;
    logic do_sra , do_beq , do_bne , do_blt , do_bge , do_bgeu, do_bltu;
    logic do_mul , do_mulh, do_mulhsu, do_mulhu, do_div, do_divu, do_rem, do_remu;
    logic do_ctz;

    logic [6:0] opcode;
    logic [6:0] funct7;
    logic [2:0] funct3;

    assign ALUControl = {`ALU_OP_WIDTH{do_add   }} & OP_ADD    |
                        {`ALU_OP_WIDTH{do_sub   }} & OP_SUB    |
                        {`ALU_OP_WIDTH{do_and   }} & OP_AND    |
                        {`ALU_OP_WIDTH{do_or    }} & OP_OR     |
                        {`ALU_OP_WIDTH{do_xor   }} & OP_XOR    |
                        {`ALU_OP_WIDTH{do_sll   }} & OP_SLL    |
                        {`ALU_OP_WIDTH{do_srl   }} & OP_SRL    |
                        {`ALU_OP_WIDTH{do_sra   }} & OP_SRA    |
                        {`ALU_OP_WIDTH{do_beq   }} & OP_BEQ    |
                        {`ALU_OP_WIDTH{do_bne   }} & OP_BNE    |
                        {`ALU_OP_WIDTH{do_blt   }} & OP_BLT    |
                        {`ALU_OP_WIDTH{do_bge   }} & OP_BGE    |
                        {`ALU_OP_WIDTH{do_bgeu  }} & OP_BGEU   |
                        {`ALU_OP_WIDTH{do_bltu  }} & OP_BLTU   |
                        {`ALU_OP_WIDTH{do_mul   }} & OP_MUL    |
                        {`ALU_OP_WIDTH{do_mulh  }} & OP_MULH   |
                        {`ALU_OP_WIDTH{do_mulhsu}} & OP_MULHSU |
                        {`ALU_OP_WIDTH{do_mulhu }} & OP_MULHU  |
                        {`ALU_OP_WIDTH{do_div   }} & OP_DIV    |
                        {`ALU_OP_WIDTH{do_divu  }} & OP_DIVU   |
                        {`ALU_OP_WIDTH{do_rem   }} & OP_REM    |
                        {`ALU_OP_WIDTH{do_remu  }} & OP_REMU |
                        {`ALU_OP_WIDTH{do_ctz}} & OP_CTZ;

    logic kind_r, kind_i, kind_load, kind_store, kind_jalr, kind_auipc, kind_branch;
    logic       r_base, r_mext, i_shift_base;

    assign opcode       = instr[6:0];
    assign funct7       = instr[31:25];
    assign funct3       = instr[14:12];
    assign kind_r       = (opcode == `R_TYPE );
    assign kind_i       = (opcode == `I_TYPE );
    assign kind_load    = (opcode == `IL_TYPE);
    assign kind_store   = (opcode == `S_TYPE );
    assign kind_jalr    = (opcode == `IJ_TYPE);
    assign kind_auipc   = (opcode == `UA_TYPE);
    assign kind_branch  = (opcode == `B_TYPE );
    assign r_base       = kind_r && (funct7 == 7'b0000000 || funct7 == 7'b0100000);
    assign r_mext       = kind_r && (funct7 == 7'b0000001);
    assign i_shift_base = kind_i && (funct7 == 7'b0000000 || funct7 == 7'b0100000);

    assign do_add = (r_base      && funct7 == 7'b0000000 && funct3 == 3'b000) ||
                    (kind_i      && funct3 == 3'b000 ) ||
                    (kind_load   && funct3 == 3'b000 ) ||
                    (kind_load   && funct3 == 3'b001 ) ||
                    (kind_load   && funct3 == 3'b010 ) ||
                    (kind_load   && funct3 == 3'b100 ) ||
                    (kind_load   && funct3 == 3'b101 ) ||
                    (kind_store  && funct3 == 3'b000 ) ||
                    (kind_store  && funct3 == 3'b001 ) ||
                    (kind_store  && funct3 == 3'b010 ) ||
                     kind_auipc                              ||
                    (kind_jalr   && funct3 == 3'b000 );

    assign do_sub  = r_base && funct7 == 7'b0100000 && funct3 == 3'b000;

    assign do_and  = (r_base && funct7 == 7'b0000000 && funct3 == 3'b111) || (kind_i && funct3 == 3'b111);
    assign do_or   = (r_base && funct7 == 7'b0000000 && funct3 == 3'b110) || (kind_i && funct3 == 3'b110);
    assign do_xor  = (r_base && funct7 == 7'b0000000 && funct3 == 3'b100) || (kind_i && funct3 == 3'b100);

    assign do_sll  = ((r_base && funct7 == 7'b0000000) || (i_shift_base && funct7 == 7'b0000000)) && funct3 == 3'b001;
    assign do_srl  = ((r_base && funct7 == 7'b0000000) || (i_shift_base && funct7 == 7'b0000000)) && funct3 == 3'b101;
    assign do_sra  = ((r_base && funct7 == 7'b0100000) || (i_shift_base && funct7 == 7'b0100000)) && funct3 == 3'b101;

    assign do_bltu = (r_base && funct7 == 7'b0000000 && funct3 == 3'b011) || (kind_branch && funct3 == 3'b110) || (kind_i && funct3 == 3'b011);
    assign do_blt  = (r_base && funct7 == 7'b0000000 && funct3 == 3'b010) || (kind_branch && funct3 == 3'b100) || (kind_i && funct3 == 3'b010);
    assign do_beq  = kind_branch && funct3 == 3'b000;
    assign do_bne  = kind_branch && funct3 == 3'b001;
    assign do_bge  = kind_branch && funct3 == 3'b101;
    assign do_bgeu = kind_branch && funct3 == 3'b111;

    assign do_mul    = r_mext && funct3 == 3'b000;
    assign do_mulh   = r_mext && funct3 == 3'b001;
    assign do_mulhsu = r_mext && funct3 == 3'b010;
    assign do_mulhu  = r_mext && funct3 == 3'b011;
    assign do_div    = r_mext && funct3 == 3'b100;
    assign do_divu   = r_mext && funct3 == 3'b101;
    assign do_rem    = r_mext && funct3 == 3'b110;
    assign do_remu   = r_mext && funct3 == 3'b111;
    assign do_ctz = kind_i && instr[31:20] == 12'h601 && funct3 == 3'h1;
endmodule
