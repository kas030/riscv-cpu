// =============================================================================
// NPC.sv —— 下一 PC 计算
//   位于 EX 级，根据 npc_op 选择四种 PC 重定向方式：
//     2'b00  顺序执行（pc + 4）
//     2'b01  条件分支：isTrue 决定 (pc+offset) 还是 (pc+4)
//     2'b10  jalr / mret 等（offset 即目标地址，强制最低位清零）
//     2'b11  jal（pc + offset）
//   pcadd4 单独引出供 EX/MEM 寄存器锁存，避免后级再次重算。
// =============================================================================
module NPC #(
    parameter   DATAWIDTH = 32
)(
    input  logic                   isTrue ,                // 分支条件成立
    input  logic [1:0]             npc_op ,                // PC 重定向类型
    input  logic [DATAWIDTH - 1:0] pc     ,                // 当前 PC
    input  logic [DATAWIDTH - 1:0] offset ,                // 立即数 / 目标地址
    output logic [DATAWIDTH - 1:0] npc    ,                // 下一 PC
    output logic [DATAWIDTH - 1:0] pcadd4                  // pc + 4，单独输出
);
    // 一热标志，对应四种重定向类型
    logic sel_add4, sel_branch, sel_jalr, sel_jal;
    assign sel_add4   = (npc_op == 2'b00);
    assign sel_branch = (npc_op == 2'b01);
    assign sel_jalr   = (npc_op == 2'b10);
    assign sel_jal    = (npc_op == 2'b11);

    // 三类跳转目标地址
    logic [DATAWIDTH-1:0] addr_branch, addr_jalr, addr_jal;
    assign addr_branch = isTrue ? (pc + offset) : (pc + 4);                // 分支：成立才跳
    assign addr_jalr   = offset & {{DATAWIDTH - 1{1'b1}}, 1'b0};           // jalr：最低位置零
    assign addr_jal    = pc + offset;                                      // jal：pc 相对

    // 一热多路选择，未命中位为 0，按位或合并即可
    assign npc = {32{sel_add4  }} & pcadd4      |
                 {32{sel_branch}} & addr_branch |
                 {32{sel_jalr  }} & addr_jalr   |
                 {32{sel_jal   }} & addr_jal;

    assign pcadd4 = pc + 4;                                                // 顺序 PC，供后级使用
endmodule
