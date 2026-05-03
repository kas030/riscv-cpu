`timescale 1ns / 1ps

module myCPU_if_stage #(
    parameter DATAWIDTH = 32,
    parameter RESET_VAL = 32'h8000_0000
) (
    input  logic [DATAWIDTH - 1:0] irom_data,
    input  logic [DATAWIDTH - 1:0] IF_npc_redirect,
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   Stall,
    input  logic                   BranchTaken,
    output logic [DATAWIDTH - 1:0] irom_addr,
    output logic [DATAWIDTH - 1:0] IF_pc,
    output logic [DATAWIDTH - 1:0] IF_instr
);
    logic [DATAWIDTH - 1:0] IF_next_pc;

    assign IF_next_pc = BranchTaken ? IF_npc_redirect : (IF_pc + 4);

    PC #(DATAWIDTH, RESET_VAL) pc_inst (
        .clk    (clk),
        .rst    (rst),
        .en     (~Stall),
        .npc    (IF_next_pc),
        .pc_out (IF_pc)
    );

    assign irom_addr = IF_pc;
    assign IF_instr  = irom_data;
endmodule
