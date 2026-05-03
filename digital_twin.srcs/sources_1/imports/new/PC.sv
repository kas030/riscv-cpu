`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2024/04/08 12:42:16
// Design Name: 
// Module Name: PC
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module PC#(
    parameter   DATAWIDTH   = 32              ,
    parameter   RESET_VAL   = 32'h8000_0000
)(
    input  logic                   clk  ,
    input  logic                   rst,
    input  logic                   en   ,
    input  logic [DATAWIDTH - 1:0] npc  ,
    output logic [DATAWIDTH - 1:0] pc_out
);
    logic [DATAWIDTH - 1:0] reg_pc;

    always_ff @(posedge clk, posedge rst) begin
        if (rst) reg_pc <= RESET_VAL;
        else if (en) reg_pc <= npc;
    end

    assign pc_out = reg_pc;
endmodule