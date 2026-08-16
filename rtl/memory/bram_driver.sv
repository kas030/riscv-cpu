`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/22/2025 11:42:01 AM
// Design Name: 
// Module Name: bram_driver
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


module bram_driver(
    input  logic         clk				,

    input  logic [17:0]  perip_addr			,
    input  logic [31:0]  perip_wdata		,
	input  logic [1:0]	 perip_mask			,
    input  logic         bram_ren           ,
    input  logic         bram_wen           ,
    output logic [31:0]  perip_rdata		
);
    logic [15:0] bram_addr;
    logic [ 1:0] offset;
    logic [31:0] bram_wdata, bram_rdata_raw;
    logic [3:0]  bram_we;

    assign bram_addr = perip_addr[17:2];
    assign offset = perip_addr[1:0];
    // CPU 会将所有 BRAM load 请求强制为完整字读取，byte/half
    // 选择及符号扩展在 CPU 后端完成。这里直接返回 BRAM 原始字，
    // 避免在同步 BRAM 输出后串联一组不会被使用的读 mask 网络。
    assign perip_rdata = bram_rdata_raw;

    BRAM Mem_BRAM (
        .clka       (clk),
        .ena        (bram_ren),
        .wea        (4'b0000),
        .addra      (bram_addr),
        .dina       (32'b0),
        .douta      (bram_rdata_raw),
        .clkb       (clk),
        .enb        (bram_wen),
        .web        (bram_we),
        .addrb      (bram_addr),
        .dinb       (bram_wdata),
        .doutb      ()
    );

    // BRAM byte write enable 直接完成 sb/sh/sw，避免异步读改写组合路径。
    always_comb begin
        bram_we    = 4'b0000;
        bram_wdata = 32'b0;
        case (perip_mask)
            2'b10: begin
                bram_we    = 4'b1111;
                bram_wdata = perip_wdata;
            end
            2'b01: begin
                bram_we    = offset[1] ? 4'b1100 : 4'b0011;
                bram_wdata = offset[1] ? {perip_wdata[15:0], 16'b0} :
                                          {16'b0, perip_wdata[15:0]};
            end
            2'b00: begin
                case (offset)
                    2'b00: begin bram_we = 4'b0001; bram_wdata = {24'b0, perip_wdata[7:0]}; end
                    2'b01: begin bram_we = 4'b0010; bram_wdata = {16'b0, perip_wdata[7:0], 8'b0}; end
                    2'b10: begin bram_we = 4'b0100; bram_wdata = {8'b0, perip_wdata[7:0], 16'b0}; end
                    2'b11: begin bram_we = 4'b1000; bram_wdata = {perip_wdata[7:0], 24'b0}; end
                endcase
            end
            default: begin
                bram_we    = 4'b1111;
                bram_wdata = perip_wdata;
            end
        endcase
    end
endmodule
