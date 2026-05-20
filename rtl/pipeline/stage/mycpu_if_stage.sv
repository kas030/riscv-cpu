`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护 pc_reg 寄存器，根据 EX 级修正或 IF 级静态预测选择下一 pc_reg
//   - 条件分支采用 BTFNT 静态预测：后向分支预测 taken，前向分支预测 not-taken
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
    input  logic                   BranchRedirect  ,        // EX 级发现预测错误/未预测跳转
    output logic [DATAWIDTH - 1:0] irom_addr       ,        // 取指地址
    output logic [DATAWIDTH - 1:0] IF_pc           ,        // 当前 pc_reg
    output logic [DATAWIDTH - 1:0] IF_instr         ,        // 当前取到的指令
    output logic                   IF_pred_taken   ,        // IF 级预测本条条件分支 taken
    output logic [DATAWIDTH - 1:0] IF_pred_next_pc          // IF 级预测的下一 pc_reg
);
    logic [DATAWIDTH - 1:0] IF_pcadd4;
    logic [DATAWIDTH - 1:0] IF_b_imm;
    logic [DATAWIDTH - 1:0] IF_next_pc;
    logic                   IF_is_branch;

    assign IF_instr     = irom_data;
    assign IF_pcadd4    = IF_pc + 4;
    assign IF_is_branch = (IF_instr[6:0] == `B_TYPE);
    assign IF_b_imm     = {{20{IF_instr[31]}}, IF_instr[7], IF_instr[30:25], IF_instr[11:8], 1'b0};

    // BTFNT：后向条件分支（立即数为负）预测 taken，其余顺序执行。
    assign IF_pred_taken   = IF_is_branch && IF_instr[31];
    assign IF_pred_next_pc = IF_pred_taken ? (IF_pc + IF_b_imm) : IF_pcadd4;

    // EX 级修正优先级最高；没有修正时按 IF 级预测推进。
    assign IF_next_pc = BranchRedirect ? IF_npc_redirect : IF_pred_next_pc;

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
endmodule
