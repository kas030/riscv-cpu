`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 04/16/2025 06:04:59 PM
// Design Name: 
// Module Name: twin_controller
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


module twin_controller(
    input wire clk,
    input wire rst_n,

    input wire rx_ready,
    input wire [7:0] rx_data,

    output reg tx_start,
    output reg [7:0] tx_data,
    input wire tx_busy,

    output reg [63:0] sw,
    output reg [7:0] key,
    input wire [39:0] seg,
    input wire [31:0] led,

    /* CPU 串口透传（接 uart_bridge 50MHz 侧，经 perip_bridge）
     * 协议：0xC9 进入透传，0xCA 退出（index 73/74，原协议静默忽略区）
     * 透传中所有字节（含 0x80）转发 CPU；SW/KEY 注入暂停 */
    input  wire [7:0]  cpu_uart_tx_data,
    input  wire        cpu_uart_tx_start,
    output reg  [7:0]  cpu_uart_rx_data,
    output reg         cpu_uart_rx_valid,
    output wire        passthrough      // 透传态（供 uart_bridge 清挂起 TX）
);

    assign passthrough = (current_state == PASSTHROUGH);

    typedef enum reg [1:0] {
        IDLE         = 2'd0,
        SEND         = 2'd1,
        PASSTHROUGH  = 2'd2
    } state_t;

    reg [4:0] send_cnt;
    reg [7:0] status_buffer[0:17];
    reg [7:0] tx_data_next;
    reg tx_start_next;

    state_t current_state, next_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            current_state <= IDLE;
        else
            current_state <= next_state;
    end

    always @(*) begin
        next_state = current_state;
        tx_start_next = 0;
        tx_data_next = tx_data;

        case(current_state)
            IDLE: begin
                if(rx_ready) begin
                    if(rx_data == 8'h80) begin
                        next_state = SEND;
                        tx_start_next = 0;
                    end else if(rx_data == 8'hC9) begin
                        /* 进入 CPU 串口透传（0xC9 不转发） */
                        next_state = PASSTHROUGH;
                        tx_start_next = 0;
                    end else begin
                        next_state = IDLE;
                        if(rx_data[6:0] <= 72 && rx_data[6:0] >= 1) begin
                            tx_start_next = 0;
                        end
                    end
                end
            end
            SEND: begin
                if(~tx_busy) begin
                    tx_data_next = status_buffer[send_cnt];  
                    tx_start_next = 1;                      
                    if (send_cnt == 17)
                        next_state = IDLE;
                end
            end
            PASSTHROUGH: begin
                if(rx_ready && rx_data == 8'hCA) begin
                    /* 退出透传（0xCA 不转发 CPU） */
                    next_state = IDLE;
                end else begin
                    next_state = PASSTHROUGH;
                end
                tx_start_next = 0;
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_start <= 0;
            tx_data <= 8'd0;
        end else begin
            /* 透传中 uart 发送由 CPU（uart_bridge）驱动，原协议输出被旁路；
             * pt_first=0 的进入首拍不转发（bridge 清挂起 tx_req 的同拍） */
            tx_start <= (current_state == PASSTHROUGH && pt_first) ? cpu_uart_tx_start : tx_start_next;
            tx_data  <= (current_state == PASSTHROUGH) ? cpu_uart_tx_data  : tx_data_next;
        end
    end

    reg tx_start_d; // send_cnt should only add once in a tx process

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_start_d <= 0;
        end else begin
            tx_start_d <= tx_start;
        end
    end

    /* 透传进入首拍抑制转发：bridge 在透传上升沿才清挂起 tx_req，
     * 同拍转发会让 uart 锁存透传前 CPU 的旧字节。pt_first 为进入后
     * 首拍标志（1 拍延迟），首拍输出 0，次拍起正常转发 */
    reg pt_first;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pt_first <= 1'b0;
        end else begin
            pt_first <= (current_state == PASSTHROUGH);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_cnt <= 0;
        end else if(current_state == IDLE) begin
            send_cnt <= 0;
        end else if(current_state == SEND && tx_start && ~tx_start_d) begin
            send_cnt <= send_cnt + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sw <= 64'd0;
            key <= 8'd0;
        end else if(rx_ready && rx_data != 8'h80 && rx_data != 8'h0 && current_state != PASSTHROUGH) begin
            if(rx_data[6:0] <= 64)
                sw[rx_data[6:0] - 1] <= rx_data[7];
            else if(rx_data[6:0] <= 72)
                key[rx_data[6:0] - 65] <= rx_data[7];
        end
    end

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for(i = 0; i < 18; i = i + 1)
                status_buffer[i] <= 8'd0;
        end else if(rx_ready && rx_data == 8'h80 && current_state == IDLE) begin
            // seg: 40bit
            status_buffer[0]  <= seg[7:0];
            status_buffer[1]  <= seg[15:8];
            status_buffer[2]  <= seg[23:16];
            status_buffer[3]  <= seg[31:24];
            status_buffer[4]  <= seg[39:32];

            // key: 8bit
            status_buffer[5]  <= key;

            // sw: 64bit
            status_buffer[6]  <= sw[7:0];
            status_buffer[7]  <= sw[15:8];
            status_buffer[8]  <= sw[23:16];
            status_buffer[9]  <= sw[31:24];
            status_buffer[10] <= sw[39:32];
            status_buffer[11] <= sw[47:40];
            status_buffer[12] <= sw[55:48];
            status_buffer[13] <= sw[63:56];

            // led: 32bit
            status_buffer[14] <= led[7:0];
            status_buffer[15] <= led[15:8];
            status_buffer[16] <= led[23:16];
            status_buffer[17] <= led[31:24];
        end
    end

    /* CPU 串口透传输出：透传中除退出字节 0xCA 外全部转发（含 0x80）
     * 用 rx_ready 上升沿（~rx_ready_d）触发：进入透传的 0xC9 在 IDLE 期
     * 已拉高 rx_ready，不会被转发给 CPU */
    reg rx_ready_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_ready_d <= 1'b0;
        end else begin
            rx_ready_d <= rx_ready;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_uart_rx_data  <= 8'd0;
            cpu_uart_rx_valid <= 1'b0;
        end else begin
            cpu_uart_rx_data  <= rx_data;
            cpu_uart_rx_valid <= (current_state == PASSTHROUGH) && rx_ready && ~rx_ready_d && (rx_data != 8'hCA);
        end
    end

endmodule

