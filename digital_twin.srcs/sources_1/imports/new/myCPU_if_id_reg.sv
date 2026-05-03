`timescale 1ns / 1ps

module myCPU_if_id_reg #(
    parameter DATAWIDTH = 32,
    parameter NOP_INSTR = 32'h0000_0013
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   Flush_IF_ID,
    input  logic                   Stall,
    input  logic [DATAWIDTH - 1:0] IF_pc,
    input  logic [DATAWIDTH - 1:0] IF_instr,
    output logic [DATAWIDTH - 1:0] ID_pc,
    output logic [DATAWIDTH - 1:0] ID_instr
);
    always_ff @(posedge clk) begin
        if (rst || Flush_IF_ID) begin
            ID_pc    <= '0;
            ID_instr <= NOP_INSTR;
        end else if (!Stall) begin
            ID_pc    <= IF_pc;
            ID_instr <= IF_instr;
        end
    end
endmodule
