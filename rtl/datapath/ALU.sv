// =============================================================================
// ALU.sv —— 32 位算术逻辑单元
//   位于 EX 级，根据 ACTL 译码出的 14 位独热 ALUControl 选择本次运算：
//     [0] add  [1] sub  [2] and [3] or  [4] xor [5] sll [6] srl [7] sra
//     [8] beq  [9] bne [10] blt [11] bge [12] bgeu [13] bltu
//   add/sub/blt/bge/bgeu/bltu 共享同一加减法器（B 端按需取反 + cin=1）
//   以减少加法器实例，并在 isTrue 上输出"分支条件成立"标志供 NPC 使用。
// =============================================================================
module ALU #(
    parameter   DATAWIDTH = 32
)(
    input  logic [DATAWIDTH - 1:0]  A          ,           // ALU A 端（来自前递 / pc）
    input  logic [DATAWIDTH - 1:0]  B          ,           // ALU B 端（来自前递 / imm）
    input  logic [13:0]             ALUControl ,           // 独热操作码
    output logic [DATAWIDTH - 1:0]  Result     ,           // 运算结果
    output logic                    isTrue                 // 分支条件成立（仅最低位有效）
);
    // 把 14 位独热码拆出来，便于后面按位与汇合
    logic m_add , m_sub , m_and , m_or  , m_xor , m_sll , m_srl;
    logic m_sra , m_beq , m_bne , m_blt , m_bge , m_bgeu, m_bltu;
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

    // 共享加减法器：减法/比较时把 B 取反 + cin=1，等价于 A + (~B) + 1 = A - B
    logic [DATAWIDTH-1:0] add_lhs, add_rhs;
    logic                 cin, cout;
    assign add_lhs = A;
    assign add_rhs = (m_sub | m_blt | m_bge | m_bgeu | m_bltu) ? ~B : B;
    assign cin     = (m_sub | m_blt | m_bge | m_bgeu | m_bltu) ? 1'b1 : 1'b0;

    // 各通路计算（全部并行，最后一热汇总）
    logic [DATAWIDTH-1:0] r_addsub, r_and, r_or, r_xor;
    logic [DATAWIDTH-1:0] r_sll, r_srl, r_sra;
    logic [DATAWIDTH-1:0] r_beq, r_bne, r_blt, r_bge, r_bgeu, r_bltu;

    /* verilator lint_off WIDTHEXPAND */
    assign {cout, r_addsub} = add_lhs + add_rhs + cin;     // 加减法器主路

    assign r_and  = A & B;
    assign r_or   = A | B;
    assign r_xor  = A ^ B;
    assign r_sll  = A << B[4:0];
    assign r_srl  = A >> B[4:0];
    assign r_sra  = ($signed(A)) >>> B[4:0];               // 算术右移要保留符号

    // 比较类一律用最低位表示真假，方便 NPC 直接看 isTrue
    assign r_beq  = {31'b0,  A == B};
    assign r_bne  = {31'b0,  A != B};
    assign r_blt  = {31'b0, (A[31] &  ~B[31]) | ((~A[31] ^ B[31]) & r_addsub[31])};
    assign r_bge  = ~r_blt;
    assign r_bgeu = {31'b0,  cout};
    assign r_bltu = {31'b0, ~cout};

    // 分支条件成立 = Result 最低位
    assign isTrue = Result[0];

    // 一热多路汇合输出
    assign Result = {32{m_add | m_sub}} & r_addsub |
                    {32{m_and        }} & r_and    |
                    {32{m_or         }} & r_or     |
                    {32{m_xor        }} & r_xor    |
                    {32{m_sll        }} & r_sll    |
                    {32{m_srl        }} & r_srl    |
                    {32{m_sra        }} & r_sra    |
                    {32{m_beq        }} & r_beq    |
                    {32{m_bne        }} & r_bne    |
                    {32{m_blt        }} & r_blt    |
                    {32{m_bge        }} & r_bge    |
                    {32{m_bgeu       }} & r_bgeu   |
                    {32{m_bltu       }} & r_bltu;
endmodule
