// =============================================================================
// alu.sv —— 32 位算术逻辑单元
//   位于 EX 级，根据 alu_ctrl 译码出的独热 ALUControl 选择本次运算：
//     [0] add  [1] sub  [2] and [3] or  [4] xor [5] sll [6] srl [7] sra
//     [8] beq  [9] bne [10] blt [11] bge [12] bgeu [13] bltu
//   设计要点：
//     - add/sub/blt/bge/bgeu/bltu 共享同一加减法器，减法/比较时通过
//       B 端取反 + cin=1 实现 A - B。
//     - 比较类结果只关心 bit0，isTrue 由比较通路单独生成，避免分支时序
//       依赖整张 Result 汇总网络。
//     - RV32M 在 EX 级由独立多周期单元处理，不再放在本 alu 的组合路径里。
// =============================================================================
`include "../common/defines.sv"

module alu #(
    parameter DATAWIDTH = 32
)(
    input  logic [DATAWIDTH - 1:0]         A          ,
    input  logic [DATAWIDTH - 1:0]         B          ,
    input  logic [`ALU_OP_WIDTH - 1:0]     ALUControl ,
    output logic [DATAWIDTH - 1:0]         Result     ,
    output logic                           isTrue
);
    logic m_add , m_sub , m_and , m_or  , m_xor , m_sll , m_srl;
    logic m_sra , m_beq , m_bne , m_blt , m_bge , m_bgeu, m_bltu;
    logic m_bset;
    logic [DATAWIDTH-1:0] add_lhs, add_rhs;
    logic                 cin, cout;
    logic [DATAWIDTH-1:0] r_addsub, r_and, r_or, r_xor;
    logic [DATAWIDTH-1:0] r_sll, r_srl, r_sra;
    logic [DATAWIDTH-1:0] r_slt, r_sltu;
    logic [DATAWIDTH-1:0] r_bset;
    logic                 cmp_eq, cmp_lt, cmp_ltu;

    assign m_add  = ALUControl[ 0];
    assign m_sub  = ALUControl[ 1];
    assign m_and  = ALUControl[ 2];
    assign m_or   = ALUControl[ 3];
    assign m_xor  = ALUControl[ 4];
    assign m_sll  = ALUControl[ 5];
    assign m_srl  = ALUControl[ 6];
    assign m_sra  = ALUControl[ 7];
    assign m_beq  = ALUControl[ 8];
    assign m_bne  = ALUControl[ 9];
    assign m_blt  = ALUControl[10];
    assign m_bge  = ALUControl[11];
    assign m_bgeu = ALUControl[12];
    assign m_bltu = ALUControl[13];
    assign m_bset = ALUControl[22];

    assign add_lhs = A;
    assign add_rhs = (m_sub | m_blt | m_bge | m_bgeu | m_bltu) ? ~B : B;
    assign cin     = (m_sub | m_blt | m_bge | m_bgeu | m_bltu) ? 1'b1 : 1'b0;

    /* verilator lint_off WIDTHEXPAND */
    assign {cout, r_addsub} = add_lhs + add_rhs + cin;
    /* verilator lint_on WIDTHEXPAND */

    assign r_and  = A & B;
    assign r_or   = A | B;
    assign r_xor  = A ^ B;
    assign r_sll  = A << B[4:0];
    assign r_srl  = A >> B[4:0];
    assign r_sra  = ($signed(A)) >>> B[4:0];
    assign r_bset = A | (32'b1 << B[4:0]);

    assign cmp_eq  = A == B;
    assign cmp_lt  = (A[31] &  ~B[31]) | ((~A[31] ^ B[31]) & r_addsub[31]);
    assign cmp_ltu = ~cout;
    assign r_slt   = {{DATAWIDTH - 1{1'b0}},  cmp_lt };
    assign r_sltu  = {{DATAWIDTH - 1{1'b0}},  cmp_ltu};

    assign isTrue = (m_beq  &  cmp_eq ) |
                    (m_bne  & ~cmp_eq ) |
                    (m_blt  &  cmp_lt ) |
                    (m_bge  & ~cmp_lt ) |
                    (m_bgeu & ~cmp_ltu) |
                    (m_bltu &  cmp_ltu);

    assign Result = {DATAWIDTH{m_add | m_sub}} & r_addsub |
                    {DATAWIDTH{m_and        }} & r_and    |
                    {DATAWIDTH{m_or         }} & r_or     |
                    {DATAWIDTH{m_xor        }} & r_xor    |
                    {DATAWIDTH{m_sll        }} & r_sll    |
                    {DATAWIDTH{m_srl        }} & r_srl    |
                    {DATAWIDTH{m_sra        }} & r_sra    |
                    {DATAWIDTH{m_blt        }} & r_slt    |
                    {DATAWIDTH{m_bltu       }} & r_sltu |
                    {DATAWIDTH{m_bset}} & r_bset;
endmodule
