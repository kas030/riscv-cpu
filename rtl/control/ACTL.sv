// =============================================================================
// ACTL.sv —— ALU 控制译码
//   位于 ID 级，根据 opcode + funct[3:0] 译码出 14 位独热 ALUControl，
//   每一位对应 ALU 的一种运算（add/sub/and/or/xor/sll/srl/sra/各类比较）。
//   一热编码使得 ALU 内部可以用按位与 + 或汇总，避免使用 case，
//   有利于布局布线时分散到多 LUT 上从而缩短关键路径。
// =============================================================================
`include "../common/defines.sv"

module ACTL(
    input  logic [6:0]  opcode    ,                         // 指令 opcode
    input  logic [3:0]  funct     ,                         // {instr[30], funct3}
    output logic [13:0] ALUControl                          // 独热 ALU 操作码
);
    // 14 个一热常量，与 ALU.sv 中 ALUControl 各 bit 一一对应
    localparam OP_ADD  = 14'h0001;
    localparam OP_SUB  = 14'h0002;
    localparam OP_AND  = 14'h0004;
    localparam OP_OR   = 14'h0008;
    localparam OP_XOR  = 14'h0010;
    localparam OP_SLL  = 14'h0020;
    localparam OP_SRL  = 14'h0040;
    localparam OP_SRA  = 14'h0080;
    localparam OP_BEQ  = 14'h0100;
    localparam OP_BNE  = 14'h0200;
    localparam OP_BLT  = 14'h0400;
    localparam OP_BGE  = 14'h0800;
    localparam OP_BGEU = 14'h1000;
    localparam OP_BLTU = 14'h2000;

    // 各运算独热标志
    logic do_add , do_sub , do_and , do_or  , do_xor , do_sll , do_srl;
    logic do_sra , do_beq , do_bne , do_blt , do_bge , do_bgeu, do_bltu;

    // 按一热标志聚合输出
    assign ALUControl = {14{do_add }} & OP_ADD  |
                        {14{do_sub }} & OP_SUB  |
                        {14{do_and }} & OP_AND  |
                        {14{do_or  }} & OP_OR   |
                        {14{do_xor }} & OP_XOR  |
                        {14{do_sll }} & OP_SLL  |
                        {14{do_srl }} & OP_SRL  |
                        {14{do_sra }} & OP_SRA  |
                        {14{do_beq }} & OP_BEQ  |
                        {14{do_bne }} & OP_BNE  |
                        {14{do_blt }} & OP_BLT  |
                        {14{do_bge }} & OP_BGE  |
                        {14{do_bgeu}} & OP_BGEU |
                        {14{do_bltu}} & OP_BLTU;

    // 指令类型独热（仅在本模块内部使用）
    logic kind_r, kind_i, kind_load, kind_store, kind_jalr, kind_auipc, kind_branch;
    assign kind_r      = (opcode == `R_TYPE );
    assign kind_i      = (opcode == `I_TYPE );
    assign kind_load   = (opcode == `IL_TYPE);
    assign kind_store  = (opcode == `S_TYPE );
    assign kind_jalr   = (opcode == `IJ_TYPE);
    assign kind_auipc  = (opcode == `UA_TYPE);
    assign kind_branch = (opcode == `B_TYPE );

    // ADD：R/I 型 ADD、各种 load/store 地址计算、auipc 偏移、jalr 目标地址
    assign do_add = (kind_r      && funct       == 4'b0000) ||
                    (kind_i      && funct[2:0]  == 3'b000 ) ||
                    (kind_load   && funct[2:0]  == 3'b000 ) ||
                    (kind_load   && funct[2:0]  == 3'b001 ) ||
                    (kind_load   && funct[2:0]  == 3'b010 ) ||
                    (kind_load   && funct[2:0]  == 3'b100 ) ||
                    (kind_load   && funct[2:0]  == 3'b101 ) ||
                    (kind_store  && funct[2:0]  == 3'b000 ) ||
                    (kind_store  && funct[2:0]  == 3'b001 ) ||
                    (kind_store  && funct[2:0]  == 3'b010 ) ||
                     kind_auipc                              ||
                    (kind_jalr   && funct[2:0]  == 3'b000 );

    // SUB：仅 R 型 sub
    assign do_sub  = (kind_r && funct == 4'b1000);

    // 位逻辑：AND/OR/XOR
    assign do_and  = (kind_r && funct == 4'b0111) || (kind_i && funct[2:0] == 3'b111);
    assign do_or   = (kind_r && funct == 4'b0110) || (kind_i && funct[2:0] == 3'b110);
    assign do_xor  = (kind_r && funct == 4'b0100) || (kind_i && funct[2:0] == 3'b100);

    // 移位：SLL / SRL / SRA，funct 同时覆盖 R/I 型
    assign do_sll  = (kind_r || kind_i) && funct == 4'b0001;
    assign do_srl  = (kind_r || kind_i) && funct == 4'b0101;
    assign do_sra  = (kind_r || kind_i) && funct == 4'b1101;

    // 比较类：sltu / slt / beq / bne / bge / bgeu，分支指令复用 BLT/BGE 等比较
    assign do_bltu = (kind_r && funct == 4'b0011) || (kind_branch && funct[2:0] == 3'b110) || (kind_i && funct[2:0] == 3'b011);
    assign do_blt  = (kind_r && funct == 4'b0010) || (kind_branch && funct[2:0] == 3'b100) || (kind_i && funct[2:0] == 3'b010);
    assign do_beq  = kind_branch && funct[2:0] == 3'b000;
    assign do_bne  = kind_branch && funct[2:0] == 3'b001;
    assign do_bge  = kind_branch && funct[2:0] == 3'b101;
    assign do_bgeu = kind_branch && funct[2:0] == 3'b111;
endmodule
