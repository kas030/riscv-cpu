`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/16/2025 06:21:44 PM
// Design Name: 
// Module Name: top
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


module top(
    input  wire i_sys_clk_p         ,
    input  wire i_sys_clk_n         ,
    input  wire i_uart_rx           ,
    output wire o_uart_tx           ,

    output wire [31:0] virtual_led  ,
    output wire [39:0] virtual_seg
);

    wire w_clk_50Mhz, cpu_clk; // PLL 输出：外设 50 MHz、CPU 200 MHz
    wire w_clk_rst;

    wire [7:0] virtual_key;
    wire [63:0] virtual_sw;

    wire [7:0] rx_data;
    wire rx_ready;
    wire tx_start;
    wire [7:0] tx_data;
    wire tx_busy;

    /* CPU 串口透传（twin_controller ↔ student_top）
     * uart 的 tx_busy 同时供 twin 与 CPU 透传侧（同域，直连分叉） */
    wire [7:0] cpu_uart_tx_data;
    wire       cpu_uart_tx_start;
    wire [7:0] cpu_uart_rx_data;
    wire       cpu_uart_rx_valid;
    wire       cpu_uart_passthrough;
    wire       cpu_uart_passthrough_req;

    pll pll_inst(
        .clk_in1_p(i_sys_clk_p),
        .clk_in1_n(i_sys_clk_n),
        .clk_out1(w_clk_50Mhz),
        .clk_out2(cpu_clk),
        .locked(w_clk_rst)
    );

    uart #(
        .CLK_FREQ(50000000),
        .BAUD_RATE(9600)
    ) uart_inst(
        .clk(w_clk_50Mhz),
        .rst_n(w_clk_rst),
        .rx(i_uart_rx),
        .rx_data(rx_data),
        .rx_ready(rx_ready),
        .tx(o_uart_tx),
        .tx_data(tx_data),
        .tx_start(tx_start),
        .tx_busy(tx_busy)
    );

    twin_controller twin_controller_inst(
        .clk(w_clk_50Mhz),
        .rst_n(w_clk_rst),
        .rx_ready(rx_ready),
        .rx_data(rx_data),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx_busy(tx_busy),
        .sw(virtual_sw),
        .key(virtual_key),
        .seg(virtual_seg),
        .led(virtual_led),
        .cpu_uart_tx_data(cpu_uart_tx_data),
        .cpu_uart_tx_start(cpu_uart_tx_start),
        .cpu_uart_rx_data(cpu_uart_rx_data),
        .cpu_uart_rx_valid(cpu_uart_rx_valid),
        .passthrough(cpu_uart_passthrough),
        .passthrough_req(cpu_uart_passthrough_req)
    );

    student_top student_top_inst(
        .w_cpu_clk(cpu_clk),
        .w_clk_50Mhz(w_clk_50Mhz),
        .w_clk_rst(~w_clk_rst),
        .virtual_key(virtual_key),
        .virtual_sw(virtual_sw),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg),
        .uart_tx_busy(tx_busy),
        .uart_rx_valid(cpu_uart_rx_valid),
        .uart_rx_data(cpu_uart_rx_data),
        .uart_tx_start(cpu_uart_tx_start),
        .uart_tx_data(cpu_uart_tx_data),
        .uart_passthrough(cpu_uart_passthrough),
        .uart_passthrough_req(cpu_uart_passthrough_req)
    );

endmodule
