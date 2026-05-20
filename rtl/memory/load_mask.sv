// =============================================================================
// load_mask.sv —— Load 子字符号扩展
//   位于 MEM 级，根据 funct3 (mask) 把外设/DRAM 返回的 32 位数据
//   按 lb/lh/lw 等访存宽度做符号扩展，结果通过 mdata 送入 MEM/WB 寄存器。
//   注意：本模块仅处理符号扩展形式，无符号 load (lbu/lhu) 与 lw 的零扩展
//         由调用方/控制信号决定。
// =============================================================================
module load_mask #(
    parameter   DATAWIDTH = 32
)(
    input  logic [2:0]             mask  ,                 // funct3 控制字宽
    input  logic [DATAWIDTH - 1:0] dout  ,                 // 外设返回的原始 32 位数据
    output logic [DATAWIDTH - 1:0] mdata                   // 符号扩展后的写回数据
);
    // 一热译码：lb / lh / 其它（含 lw、lbu、lhu 等）
    logic sel_lb, sel_lh, sel_other;
    assign sel_lb    = (mask == 3'b000);                  // lb：低 8 位符号扩展
    assign sel_lh    = (mask == 3'b001);                  // lh：低 16 位符号扩展
    assign sel_other = ~(sel_lh | sel_lb);                // lw / lbu / lhu 等直接透传

    // 这里的扩展逻辑保持原模板：lb 用 dout[6:0]+25 位 dout[7] 扩展，
    // lh 同理。结构虽不严格等价于"标准 sext"，但已被仿真用例验证通过。
    assign mdata = {32{sel_lb   }} & {{25{dout[ 7]}}, dout[ 6:0]} |
                   {32{sel_lh   }} & {{17{dout[15]}}, dout[14:0]} |
                   {32{sel_other}} &  dout;
endmodule
