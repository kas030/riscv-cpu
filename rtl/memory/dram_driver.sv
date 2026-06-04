`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/22/2025 11:42:01 AM
// Design Name: 
// Module Name: dram_driver
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


module dram_driver(
    input  logic         clk				,

    input  logic [17:0]  perip_addr			,
    input  logic [31:0]  perip_wdata		,
	input  logic [1:0]	 perip_mask			,
    input  logic         dram_ren           ,
    input  logic         dram_wen           ,
    output logic [31:0]  perip_rdata		
);
    logic [15:0] bram_addr;
    logic [ 1:0] offset;
    logic [ 1:0] rmask_q, roffset_q;
    logic [31:0] bram_wdata, bram_rdata_raw, dout;
    logic [3:0]  bram_we;

    assign bram_addr = perip_addr[17:2];
    assign offset = perip_addr[1:0];
    assign perip_rdata = dout;

    DRAM Mem_DRAM (
        .clka       (clk),
        .ena        (dram_ren),
        .wea        (4'b0000),
        .addra      (bram_addr),
        .dina       (32'b0),
        .douta      (bram_rdata_raw),
        .clkb       (clk),
        .enb        (dram_wen),
        .web        (bram_we),
        .addrb      (bram_addr),
        .dinb       (bram_wdata),
        .doutb      ()
    );

    always_ff @(posedge clk) begin
        if (dram_ren) begin
            rmask_q   <= perip_mask;
            roffset_q <= offset;
        end
    end

    // BRAM 同步读返回上一拍请求的数据，这里用上一拍锁存的 mask/offset 选字节。
    always_comb begin
        dout = 0;
        case (rmask_q)
            2'b00: // lb/lbu
                case (roffset_q)
                    2'b00:  dout = {24'b0, bram_rdata_raw[7:0]};
                    2'b01:  dout = {24'b0, bram_rdata_raw[15:8]};
                    2'b10:  dout = {24'b0, bram_rdata_raw[23:16]};
                    2'b11:  dout = {24'b0, bram_rdata_raw[31:24]};
                endcase
            2'b01: // lh/lhu
                case (roffset_q[1])
                    1'b0:  dout = {24'b0, bram_rdata_raw[15:0]};
                    1'b1:  dout = {24'b0, bram_rdata_raw[31:16]};
                endcase
            2'b10: dout = bram_rdata_raw;
            default: dout = 0;
        endcase
    end

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
