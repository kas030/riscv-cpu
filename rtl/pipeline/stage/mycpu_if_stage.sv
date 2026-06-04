`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护 pc_reg 寄存器，根据预测结果选择 pc_reg+4 或预测目标
//   - EX 级发现预测错误时，优先使用 IF_npc_redirect 修正取指地址
//   - 把 pc_reg 输出到 IROM 的地址端口，IROM 同周期返回的 32 位指令直接连给
//     IF_instr，再交给 IF/ID 流水寄存器锁存。
//   - Stall=1 时由 pc_reg 模块的 en 入口冻结 pc_reg，使流水线整体停顿。
// =============================================================================
module mycpu_if_stage #(
    parameter DATAWIDTH = 32                ,
    parameter RESET_VAL = 32'h8000_0000
) (
    input  logic [DATAWIDTH - 1:0] irom_data       ,        // IROM 返回的指令
    input  logic [DATAWIDTH - 1:0] IF_npc_redirect ,        // EX 级算出的跳转目标
    input  logic                   clk             ,
    input  logic                   rst             ,
    input  logic                   Stall           ,        // load-use 等冒险时拉高
    input  logic                   BranchRedirect  ,
    input  logic                   BP_update_en    ,
    input  logic [DATAWIDTH - 1:0] BP_update_pc    ,
    input  logic                   BP_update_taken ,
    output logic [DATAWIDTH - 1:0] irom_addr       ,        // 取指地址
    output logic [DATAWIDTH - 1:0] IF_pc           ,        // 当前 pc_reg
    output logic [DATAWIDTH - 1:0] IF_instr        ,        // 当前取到的指令
    output logic                   IF_pred_taken   ,
    output logic [DATAWIDTH - 1:0] IF_pred_target
);
    // 取下一条指令地址：纠错重定向优先，其次使用动态分支预测。
    logic [DATAWIDTH - 1:0] IF_next_pc;

    branch_predictor #(DATAWIDTH) u_branch_predictor (
        .clk             (clk            ),
        .rst             (rst            ),
        .IF_pc           (IF_pc          ),
        .IF_instr        (IF_instr       ),
        .update_en       (BP_update_en   ),
        .update_pc       (BP_update_pc   ),
        .update_taken    (BP_update_taken),
        .IF_pred_taken   (IF_pred_taken  ),
        .IF_pred_target  (IF_pred_target )
    );

    assign IF_next_pc = BranchRedirect ? IF_npc_redirect :
                        IF_pred_taken  ? IF_pred_target   :
                                         (IF_pc + 4);

    // pc_reg 寄存器；Stall=1 时 en=0，pc_reg 保持
    pc_reg #(DATAWIDTH, RESET_VAL) u_pc (
        .clk    (clk        ),
        .rst    (rst        ),
        .en     (~Stall     ),
        .npc    (IF_next_pc ),
        .pc_out (IF_pc      )
    );

    // 把 pc_reg 当作取指地址送给 IROM；IROM 当周期吐出的数据即为指令
    assign irom_addr = IF_pc;
    assign IF_instr  = irom_data;
endmodule

module branch_predictor #(
    parameter DATAWIDTH   = 32,
    parameter INDEX_WIDTH = 6
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic [DATAWIDTH-1:0]   IF_pc,
    input  logic [DATAWIDTH-1:0]   IF_instr,
    input  logic                   update_en,
    input  logic [DATAWIDTH-1:0]   update_pc,
    input  logic                   update_taken,
    output logic                   IF_pred_taken,
    output logic [DATAWIDTH-1:0]   IF_pred_target
);
    localparam BHT_ENTRIES = (1 << INDEX_WIDTH);

    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [INDEX_WIDTH-1:0] IF_index;
    logic [INDEX_WIDTH-1:0] update_index;
    logic [DATAWIDTH-1:0] IF_branch_imm;
    logic IF_is_branch;

    assign IF_index     = IF_pc[INDEX_WIDTH+1:2];
    assign update_index = update_pc[INDEX_WIDTH+1:2];
    assign IF_is_branch = (IF_instr[6:0] == `B_TYPE);

    assign IF_branch_imm = {{(DATAWIDTH-13){IF_instr[31]}},
                            IF_instr[31],
                            IF_instr[7],
                            IF_instr[30:25],
                            IF_instr[11:8],
                            1'b0};

    assign IF_pred_taken  = IF_is_branch && bht[IF_index][1];
    assign IF_pred_target = IF_pc + IF_branch_imm;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= 2'b01;
            end
        end else if (update_en) begin
            if (update_taken) begin
                if (bht[update_index] != 2'b11) begin
                    bht[update_index] <= bht[update_index] + 2'b01;
                end
            end else begin
                if (bht[update_index] != 2'b00) begin
                    bht[update_index] <= bht[update_index] - 2'b01;
                end
            end
        end
    end
endmodule
