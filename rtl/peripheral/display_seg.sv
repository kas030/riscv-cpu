`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2023/09/22 13:41:36
// Design Name: 
// Module Name: display
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


module display_seg (
    input  logic          clk    ,
    input  logic          rst    ,
    input  logic [31:0]   s      ,
    input  logic [31:0]   raw_lo ,
    input  logic [31:0]   raw_hi ,
    input  logic          raw_mode,
    output logic [6:0]    seg1   ,
    output logic [6:0]    seg2   ,
    output logic [6:0]    seg3   ,
    output logic [6:0]    seg4   ,
    output logic          dp1    ,
    output logic          dp2    ,
    output logic          dp3    ,
    output logic          dp4    ,
    output logic [7:0]    ans
);
    logic  [4:0]   count;
    logic  [3:0]   digit1, digit2, digit3, digit4;
    logic  [7:0]   raw_digit1, raw_digit2, raw_digit3, raw_digit4;
    logic  [6:0]   hex_seg1, hex_seg2, hex_seg3, hex_seg4;

    always@(posedge clk or posedge rst) begin
        if(rst)  
            count <= 0;
        else 
            count <= count + 1;
    end
       
    always_comb begin
        if (count[4] == 1'b0) begin
            ans = 8'b10101010;
            digit1 = s[7:4];
            digit2 = s[15:12];
            digit3 = s[23:20];
            digit4 = s[31:28];
            raw_digit1 = raw_lo[15:8];
            raw_digit2 = raw_lo[31:24];
            raw_digit3 = raw_hi[15:8];
            raw_digit4 = raw_hi[31:24];
        end else begin
            ans = 8'b01010101;
            digit1 = s[3:0];
            digit2 = s[11:8];
            digit3 = s[19:16];
            digit4 = s[27:24];
            raw_digit1 = raw_lo[7:0];
            raw_digit2 = raw_lo[23:16];
            raw_digit3 = raw_hi[7:0];
            raw_digit4 = raw_hi[23:16];
        end
    end

    seg7 SEG1(.din(digit1), .dout(hex_seg1));
    seg7 SEG2(.din(digit2), .dout(hex_seg2));
    seg7 SEG3(.din(digit3), .dout(hex_seg3));
    seg7 SEG4(.din(digit4), .dout(hex_seg4));

    always_comb begin
        if (raw_mode) begin
            seg1 = raw_digit1[6:0];
            seg2 = raw_digit2[6:0];
            seg3 = raw_digit3[6:0];
            seg4 = raw_digit4[6:0];
            dp1 = raw_digit1[7];
            dp2 = raw_digit2[7];
            dp3 = raw_digit3[7];
            dp4 = raw_digit4[7];
        end else begin
            seg1 = hex_seg1;
            seg2 = hex_seg2;
            seg3 = hex_seg3;
            seg4 = hex_seg4;
            dp1 = 1'b0;
            dp2 = 1'b0;
            dp3 = 1'b0;
            dp4 = 1'b0;
        end
    end
endmodule
