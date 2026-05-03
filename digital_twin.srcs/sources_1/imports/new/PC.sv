// =============================================================================
// PC.sv —— 程序计数器
//   位于 IF 级，时钟上升沿在 en 有效时把 npc 锁存为新的 PC；rst 时回到
//   RESET_VAL（默认 0x8000_0000）。流水线 Stall 时 IF 级把 en 拉低，
//   使 PC 冻结一拍以等待 load-use 等冒险解除。
// =============================================================================
module PC #(
    parameter   DATAWIDTH = 32             ,
    parameter   RESET_VAL = 32'h8000_0000
)(
    input  logic                   clk    ,                // 时钟
    input  logic                   rst    ,                // 异步复位
    input  logic                   en     ,                // 写使能（Stall 时为 0 冻结 PC）
    input  logic [DATAWIDTH - 1:0] npc    ,                // 下一周期 PC 输入
    output logic [DATAWIDTH - 1:0] pc_out                  // 当前 PC 输出
);
    logic [DATAWIDTH - 1:0] pc_q;                          // 内部 PC 寄存器

    // 异步复位 + 同步使能更新
    always_ff @(posedge clk, posedge rst) begin
        if (rst)      pc_q <= RESET_VAL;                   // 复位回到入口地址
        else if (en)  pc_q <= npc;                         // 非 Stall 时正常更新
    end

    assign pc_out = pc_q;
endmodule
