`timescale 1ns / 1ps
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护 pc_reg 寄存器，根据 BranchTaken 在 (pc_reg+4) 与 IF_npc_redirect 间二选一
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
    input  logic                   BranchTaken     ,        // EX 级判跳成立
    output logic [DATAWIDTH - 1:0] irom_addr       ,        // 取指地址
    output logic [DATAWIDTH - 1:0] IF_pc           ,        // 当前 pc_reg
    output logic [DATAWIDTH - 1:0] IF_instr                 // 当前取到的指令
);
    // 取下一条指令地址：跳转命中走重定向，否则顺序 pc_reg+4
    logic [DATAWIDTH - 1:0] IF_next_pc;
    assign IF_next_pc = BranchTaken ? IF_npc_redirect : (IF_pc + 4);

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
