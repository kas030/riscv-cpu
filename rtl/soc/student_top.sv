`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/16/2025 06:21:13 PM
// Design Name: 
// Module Name: student_top
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


module student_top#(
    parameter                           P_SW_CNT            = 64,
    parameter                           P_LED_CNT           = 32,
    parameter                           P_SEG_CNT           = 40,
    parameter                           P_KEY_CNT           = 8
) (
    input                                       w_cpu_clk     ,
    input                                       w_clk_50Mhz   ,
    input                                       w_clk_rst     ,
    input  [P_KEY_CNT - 1:0]                    virtual_key   ,
    input  [P_SW_CNT  - 1:0]                    virtual_sw    ,

    output [P_LED_CNT - 1:0]                    virtual_led   ,
    output [P_SEG_CNT - 1:0]                    virtual_seg   ,

    /* CPU 串口透传（50MHz 域，接 twin_controller） */
    input                                       uart_tx_busy  ,
    input                                       uart_rx_valid ,
    input  [7:0]                                uart_rx_data  ,
    output                                      uart_tx_start ,
    output [7:0]                                uart_tx_data  ,
    input                                       uart_passthrough
);

    // IROM
    logic [31:0] pc;
    logic [31:0] pc1;
    logic [11:0] inst_addr;
    logic [11:0] inst_addr1;
    logic [31:0] instruction;
    logic [31:0] instruction1;

    // perip
    logic [31:0] perip_addr, perip_wdata, perip_rdata;
    logic perip_wen;
    logic [1:0] perip_mask;

    // 16KB = 2^12 * 32bit
    assign inst_addr  = pc[13:2];
    assign inst_addr1 = pc1[13:2];

    mycpu Core_cpu (
        .cpu_rst            (w_clk_rst),
        .cpu_clk            (w_cpu_clk),

        // Interface to IROM
        .irom_addr          (pc),
        .irom_addr1         (pc1),
        .irom_data          (instruction),
        .irom_data1         (instruction1),

        // Interface to BRAM & periphera
        .perip_addr         (perip_addr),     
        .perip_wen          (perip_wen),     
        .perip_mask         (perip_mask),   
        .perip_wdata        (perip_wdata),    
        .perip_rdata        (perip_rdata)     
    );

    IROM Mem_IROM (
        .clka       (w_cpu_clk),
        .ena        (1'b1),
        .addra      (inst_addr),
        .douta      (instruction),
        .clkb       (w_cpu_clk),
        .enb        (1'b1),
        .addrb      (inst_addr1),
        .doutb      (instruction1)
    );
    
    perip_bridge bridge_inst (
        .clk				(w_cpu_clk),
        .cnt_clk            (w_clk_50Mhz),
        .rst                (w_clk_rst),
        .perip_addr			(perip_addr),
        .perip_wdata		(perip_wdata),
        .perip_wen			(perip_wen),
        .perip_mask			(perip_mask),
        .perip_rdata		(perip_rdata),
        .virtual_sw_input	(virtual_sw),
        .virtual_key_input	(virtual_key),	
        .virtual_seg_output	(virtual_seg),
        .virtual_led_output (virtual_led),
        .uart_tx_data       (uart_tx_data),
        .uart_tx_start      (uart_tx_start),
        .uart_tx_busy       (uart_tx_busy),
        .uart_rx_data       (uart_rx_data),
        .uart_rx_ready      (uart_rx_valid),
        .uart_passthrough   (uart_passthrough)
    );

endmodule
