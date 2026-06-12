`timescale 1ns / 1ps
// =============================================================================
// mycpu_if_id_reg.sv —— IF/ID 流水线寄存器
//   - 在每个时钟上升沿把 IF 级的 (pc, instr) 锁存给 ID 级
//   - rst 或 Flush_IF_ID（跳转命中冲刷）时把 ID_instr 注入 NOP，把 ID_pc 清零
//   - Stall（load-use 等）时整体保持，配合 pc_reg 冻结一拍
// =============================================================================
module mycpu_if_id_reg #(
    parameter DATAWIDTH = 32                ,
    parameter NOP_INSTR = 32'h0000_0013                     // addi x0, x0, 0
) (
    input  logic                   clk         ,
    input  logic                   rst         ,
    input  logic                   Flush_IF_ID ,            // 跳转命中冲刷
    input  logic                   Stall       ,            // 冻结当前内容
    input  logic [DATAWIDTH - 1:0] IF_pc       ,
    input  logic [DATAWIDTH - 1:0] IF_instr    ,
    input  logic                   IF_pred_taken,
    input  logic [DATAWIDTH - 1:0] IF_pred_target,
    output logic [DATAWIDTH - 1:0] ID_pc       ,
    output logic [DATAWIDTH - 1:0] ID_instr    ,
    output logic                   ID_pred_taken,
    output logic [DATAWIDTH - 1:0] ID_pred_target
);
    always_ff @(posedge clk) begin
        if (rst || Flush_IF_ID) begin
            // 复位 / 冲刷：写入 NOP，避免后级把错路径指令当真
            ID_pc    <= '0;
            ID_instr <= NOP_INSTR;
            ID_pred_taken  <= 1'b0;
            ID_pred_target <= '0;
        end else if (!Stall) begin
            // 非 Stall 才更新；Stall 时本寄存器保持
            ID_pc    <= IF_pc;
            ID_instr <= IF_instr;
            ID_pred_taken  <= IF_pred_taken;
            ID_pred_target <= IF_pred_target;
        end
    end
endmodule
