/*
 * uart_bridge.sv —— CPU(240MHz) 与 UART(50MHz) 之间的跨时钟域寄存器桥
 *
 * 地址（perip_bridge 译码后子集，perip_addr[3:2]）：
 *   uart_addr=2'b00  UART_DATA  写=发送一字节（轮询 TX_BUSY 后再写）；
 *                               读=返回接收字节，并清除 RX_VALID（读清握手）。
 *   uart_addr=2'b01  UART_STATUS bit0=TX_BUSY，bit1=RX_VALID（均 2FF 同步）。
 *
 * 跨域握手：
 *   TX（240→50）：CPU 写 DATA 置 tx_pend；50MHz 域 2FF 采样上升沿置 tx_req，
 *     uart_tx_start = tx_req & ~tx_busy。tx_req 在 busy 期间保持，仅当 uart
 *     实际锁存本字节（busy 上升沿且 tx_req 挂起）后才撤请求并回送确认
 *     （20ns 脉冲，2FF 回 240MHz 域清 tx_pend）。非透传或进出透传时请求被
 *     twin 丢弃，此时立即撤请求并确认，避免 CPU 挂死。
 *     时序保证：确认路径比 busy 同步（1FF）多两级 FF，故 tx_pend 清除时
 *     busy 同步位必已拉高 —— STATUS bit0（tx_busy_sync | tx_pend）从写
 *     入到发送完成全程为 1，无“假空闲”空洞，CPU 轮询不会提前退出丢字节。
 *   RX（50→240）：rx_ready 上升沿锁存 rx_data_q 并置 rx_valid_q（置位优先
 *     于读清）；CPU 读 DATA 置 rx_rd_req（电平），50MHz 域 2FF 采样到后清
 *     rx_valid_q 并回送 ack（1 拍 50MHz，240MHz 必采到），再清 rx_rd_req。
 *     rx_rd_req 保持期间新字节置位优先，不丢数据。
 *
 * 复位：rst 为 240MHz 域高有效；50MHz 域复位由 rst 2FF 同步产生（与
 * uart/twin_controller 的复位同源，见 top.sv w_clk_rst）。
 */

module uart_bridge(
    input  logic        clk,        // CPU 时钟 240MHz
    input  logic        cnt_clk,    // 外设时钟 50MHz（与 uart/twin 同域）
    input  logic        rst,        // 高有效

    // CPU 侧（240MHz 域）
    input  logic [1:0]  uart_addr,  // perip_addr[3:2]
    input  logic [7:0]  uart_wdata,
    input  logic        uart_wen,
    input  logic        uart_ren,
    output logic [31:0] uart_rdata,

    // UART 侧（50MHz 域）
    output logic [7:0]  uart_tx_data,
    output logic        uart_tx_start,
    input  logic        uart_tx_busy,
    input  logic [7:0]  uart_rx_data,
    input  logic        uart_rx_ready,
    input  logic        passthrough     // twin 透传态（同 50MHz 域）：进入时清挂起 TX
);

    /* ---------------- 50MHz 域复位（rst 2FF 同步） ---------------- */
    logic [1:0] rst_sync;
    logic rst_50m;
    always_ff @(posedge cnt_clk) begin
        rst_sync <= {rst_sync[0], rst};
        rst_50m  <= rst_sync[1];
    end

    /* ---------------- TX：240MHz 域请求 ---------------- */
    logic        tx_pend;
    logic [7:0]  tx_data_q;
    logic [1:0]  pend_ack_sync;   // 50MHz 域确认，2FF 回 240MHz

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_pend   <= 1'b0;
            tx_data_q <= 8'd0;
        end else if (uart_wen && uart_addr == 2'b00) begin
            tx_pend   <= 1'b1;
            tx_data_q <= uart_wdata;
        end else if (pend_ack_sync[1]) begin
            tx_pend   <= 1'b0;
        end
    end

    /* ---------------- TX：50MHz 域握手 ---------------- */
    logic [1:0]  pend_sync;       // tx_pend 2FF
    logic        tx_req;          // 发送请求：电平保持到字节被 uart 实际锁存
    logic [1:0]  ack_dly;         // 确认脉冲（20ns，240MHz 必采到）
    logic [7:0]  tx_data_50;      // 每拍锁存 tx_data_q，采样时数据已稳定
    logic        passthrough_d;   // 透传态 1 拍延迟：进入/退出透传丢弃挂起 TX
    logic        uart_tx_busy_d;  // uart_tx_busy 1 拍延迟：busy 上升沿=uart 锁存

    always_ff @(posedge cnt_clk) begin
        if (rst_50m) begin
            pend_sync      <= 2'b00;
            tx_req         <= 1'b0;
            ack_dly        <= 2'b00;
            tx_data_50     <= 8'd0;
            passthrough_d  <= 1'b0;
            uart_tx_busy_d <= 1'b0;
        end else begin
            pend_sync      <= {pend_sync[0], tx_pend};
            uart_tx_busy_d <= uart_tx_busy;
            if (passthrough && ~passthrough_d) begin
                tx_req <= 1'b0;              // 进入透传：丢弃透传前挂起的旧请求
            end else if (pend_sync[0] && ~pend_sync[1]) begin
                tx_req <= 1'b1;              // 新挂起字节：请求发送（busy 期间保持）
            end else if (~passthrough) begin
                tx_req <= 1'b0;              // 非透传：请求被 twin 丢弃，立即撤
            end else if (uart_tx_busy && ~uart_tx_busy_d) begin
                tx_req <= 1'b0;              // 透传：uart 已锁存本字节，撤请求
            end
            /* 确认条件：非透传丢弃即确认；进入/退出透传丢弃挂起并确认；
             * 透传中仅在 uart 实际锁存后确认 —— 保证 240MHz 侧 tx_pend
             * 清除时 busy 同步位必已拉高，STATUS bit0 无“假空闲”空洞。
             * 字节在 busy 期间到达时挂起等待，绝不丢弃。 */
            ack_dly <= {ack_dly[0],
                        (pend_sync[0] && ~pend_sync[1] && ~passthrough) ||
                        (passthrough && ~passthrough_d) ||
                        (~passthrough && passthrough_d) ||
                        (passthrough && uart_tx_busy && ~uart_tx_busy_d)};
            tx_data_50     <= tx_data_q;
            passthrough_d  <= passthrough;
        end
    end

    assign uart_tx_data  = tx_data_50;
    assign uart_tx_start = tx_req & ~uart_tx_busy;

    always_ff @(posedge clk) begin
        if (rst) begin
            pend_ack_sync <= 2'b00;
        end else begin
            pend_ack_sync <= {pend_ack_sync[0], ack_dly[1]};
        end
    end

    /* ---------------- RX：50MHz 域锁存 ---------------- */
    logic        rx_ready_d, rx_pulse;
    logic        rx_valid_q;
    logic [7:0]  rx_data_q;
    logic [1:0]  rd_sync;         // rx_rd_req 2FF

    always_ff @(posedge cnt_clk) begin
        if (rst_50m) begin
            rx_ready_d <= 1'b0;
            rx_valid_q <= 1'b0;
            rx_data_q  <= 8'd0;
            rd_sync    <= 2'b00;
        end else begin
            rx_ready_d <= uart_rx_ready;
            rd_sync    <= {rd_sync[0], rx_rd_req};
            if (uart_rx_ready && ~rx_ready_d) begin
                rx_valid_q <= 1'b1;          // 置位优先，防读清竞争丢数据
                rx_data_q  <= uart_rx_data;
            end else if (rd_sync[1]) begin
                rx_valid_q <= 1'b0;
            end
        end
    end

    /* ---------------- RX：240MHz 域读清握手 ---------------- */
    logic        rx_rd_req;
    logic [1:0]  rd_ack_sync;     // 50MHz 域确认，2FF 回

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_rd_req <= 1'b0;
        end else if (uart_ren && uart_addr == 2'b00) begin
            rx_rd_req <= 1'b1;               // 读即请求清
        end else if (rd_ack_sync[1]) begin
            rx_rd_req <= 1'b0;
        end
    end

    logic rd_ack_50;                          // 50MHz 域 1 拍脉冲回送
    always_ff @(posedge cnt_clk) begin
        if (rst_50m) begin
            rd_ack_50 <= 1'b0;
        end else begin
            rd_ack_50 <= rd_sync[1];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ack_sync <= 2'b00;
        end else begin
            rd_ack_sync <= {rd_ack_sync[0], rd_ack_50};
        end
    end

    /* ---------------- RX：240MHz 域同步读 ---------------- */
    logic        rx_valid_sync;
    logic [7:0]  rx_data_d, rx_data_sync;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_valid_sync <= 1'b0;
            rx_data_d     <= 8'd0;
            rx_data_sync  <= 8'd0;
        end else begin
            rx_valid_sync <= rx_valid_q;
            rx_data_d     <= rx_data_q;
            rx_data_sync  <= rx_data_d;
        end
    end

    /* ---------------- 240MHz 域状态输出 ---------------- */
    logic        tx_busy_sync;
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_busy_sync <= 1'b0;
        end else begin
            tx_busy_sync <= uart_tx_busy;
        end
    end

    always_comb begin
        case (uart_addr)
            2'b00:   uart_rdata = {24'd0, rx_data_sync};
            /* TX_BUSY 并入 tx_pend：pend 确认（ack）晚于 busy 同步到达，
             * 若只报 uart_tx_busy，CPU 会在 pend 未清时写下一字节导致丢字节 */
            2'b01:   uart_rdata = {30'd0, rx_valid_sync, tx_busy_sync | tx_pend};
            default: uart_rdata = 32'd0;
        endcase
    end

endmodule
