// =============================================================================
// alu.sv —— 32 位算术逻辑单元
//   位于 EX 级，根据 alu_ctrl 译码出的独热 ALUControl 选择本次运算：
//     [0] add  [1] sub  [2] and [3] or  [4] xor [5] sll [6] srl [7] sra
//     [8] beq  [9] bne [10] blt [11] bge [12] bgeu [13] bltu [22] clmul
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
    logic m_sra , m_beq , m_bne , m_blt , m_bge , m_bgeu, m_bltu, m_clmul, m_crc8;
    logic [DATAWIDTH-1:0] add_lhs, add_rhs;
    logic                 cin, cout;
    logic [DATAWIDTH-1:0] r_addsub, r_and, r_or, r_xor;
    logic [DATAWIDTH-1:0] r_sll, r_srl, r_sra, r_clmul, r_crc8;
    logic [DATAWIDTH-1:0] r_logic_shift, r_non_arith;
    logic                 cmp_eq, cmp_lt, cmp_ltu, cmp_result_selected;
    integer               clmul_i;

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
    assign m_clmul = ALUControl[22];
    assign m_crc8 = ALUControl[23];

    function automatic logic [15:0] crc16_advance_byte(input logic [15:0] value);
        logic [15:0] crc;
        integer i;
        begin
            crc = value;
            for (i = 0; i < 8; i = i + 1) begin
                crc = crc[0] ? ((crc >> 1) ^ 16'ha001) : (crc >> 1);
            end
            crc16_advance_byte = crc;
        end
    endfunction

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
    always_comb begin
        r_clmul = '0;
        for (clmul_i = 0; clmul_i < DATAWIDTH; clmul_i = clmul_i + 1)
            if (B[clmul_i])
                r_clmul = r_clmul ^ (A << clmul_i);
    end
    assign r_crc8 = {{DATAWIDTH - 16{1'b0}},
                     crc16_advance_byte(A[15:0] ^ B[15:0])};

    assign cmp_eq  = A == B;
    assign cmp_lt  = (A[31] &  ~B[31]) | ((~A[31] ^ B[31]) & r_addsub[31]);
    assign cmp_ltu = ~cout;

    assign isTrue = (m_beq  &  cmp_eq ) |
                    (m_bne  & ~cmp_eq ) |
                    (m_blt  &  cmp_lt ) |
                    (m_bge  & ~cmp_lt ) |
                    (m_bgeu & ~cmp_ltu) |
                    (m_bltu &  cmp_ltu);

    // ADD/SUB 是最常见且会串接 32 位 carry chain 的结果。将它从大型
    // 独热 OR 树中单独旁路，使算术数据在 carry 后只经过一级结果 mux；
    // 分支比较继续使用上面的独立 isTrue 通路。
    assign r_logic_shift = {DATAWIDTH{m_and}} & r_and |
                           {DATAWIDTH{m_or }} & r_or  |
                           {DATAWIDTH{m_xor}} & r_xor |
                           {DATAWIDTH{m_sll}} & r_sll |
                           {DATAWIDTH{m_srl}} & r_srl |
                           {DATAWIDTH{m_sra}} & r_sra |
                           {DATAWIDTH{m_clmul}} & r_clmul |
                           {DATAWIDTH{m_crc8}} & r_crc8;

    assign cmp_result_selected = (m_blt & cmp_lt) | (m_bltu & cmp_ltu);
    assign r_non_arith = (m_blt | m_bltu) ?
                         {{DATAWIDTH - 1{1'b0}}, cmp_result_selected} :
                         r_logic_shift;

    assign Result = (m_add | m_sub) ? r_addsub : r_non_arith;
endmodule
