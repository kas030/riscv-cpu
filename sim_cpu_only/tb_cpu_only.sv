`timescale 1ns / 1ps
`include "sim_config.svh"

module tb_cpu_only;
    localparam BRAM_BASE = 32'h8010_0000;
    localparam BRAM_END  = 32'h8013_FFFF;
    localparam SW0_ADDR  = 32'h8020_0000;
    localparam SW1_ADDR  = 32'h8020_0004;
    localparam KEY_ADDR  = 32'h8020_0010;
    localparam SEG_ADDR  = 32'h8020_0020;
    localparam LED_ADDR  = 32'h8020_0040;
    localparam CNT_ADDR  = 32'h8020_0050;
    localparam UART_DATA_ADDR   = 32'h8020_0060;
    localparam UART_STATUS_ADDR = 32'h8020_0064;

    logic clk = 1'b0;
    logic cnt_clk = 1'b0;
    logic rst = 1'b1;

    logic [31:0] irom_addr;
    logic [31:0] irom_addr1;
    logic [31:0] irom_data;
    logic [31:0] irom_data1;
    logic [31:0] perip_addr;
    logic        perip_wen;
    logic [1:0]  perip_mask;
    logic [31:0] perip_wdata;
    logic [31:0] perip_rdata;

    logic [31:0] virtual_led = 32'hxxxx_xxxx;
    logic        led_written = 1'b0;
    logic [31:0] seg_wdata = 32'h3700_0000;
    logic        seg_written = 1'b0;
    logic        cnt_enable = 1'b0;
    logic [31:0] cnt_ms = 32'd0;
    logic [15:0] cnt_1ms = 16'd0;
    logic        cnt_started = 1'b0;
    time         cnt_start_time = 0;
    logic [31:0] irom [0:16383];
    logic [31:0] bram [0:65535];
    logic [31:0] bram_rdata_q;
    logic        bram_resp_valid;

    /* ---- UART 透传通路（uart/twin_controller/uart_bridge 均为真实 RTL） ---- */
    logic        uart_line_rx;        // tb 注入（模拟 PC 发送）
    logic        twin_passthrough;    // twin 透传态
    logic        twin_passthrough_req; // CPU 透传请求（bridge -> twin）
    logic        uart_line_tx;        // uart 输出（tb 捕获）
    logic [7:0]  uart_rx_data;
    logic        uart_rx_ready;
    logic [7:0]  uart_tx_data;
    logic        uart_tx_start;
    logic        uart_tx_busy;
    logic [63:0] twin_sw;
    logic [7:0]  twin_key;
    logic [7:0]  cpu_uart_tx_data;
    logic        cpu_uart_tx_start;
    logic [7:0]  cpu_uart_rx_data;
    logic        cpu_uart_rx_valid;
    logic [31:0] uart_rdata;
    logic [31:0] twin_led = 32'd0;
    logic [39:0] twin_seg = {8'd0, 32'h3700_0000};
    logic [7:0]  uart_cap_queue [0:4095];
    integer      uart_cap_qlen = 0;
    integer      uart_cap_qhead = 0;

    longint unsigned cycles = 64'd0;
    longint unsigned cnt_writeback = 64'd0;
    longint unsigned cnt_slot1_writeback = 64'd0;
    longint unsigned cnt_store = 64'd0;
    longint unsigned cnt_branch = 64'd0;
    longint unsigned cnt_dual_issue = 64'd0;
    longint unsigned cnt_stall_front = 64'd0;
    longint unsigned cnt_stall_hazard = 64'd0;
    longint unsigned cnt_load_use_ex = 64'd0;
    longint unsigned cnt_load_use_mem = 64'd0;
    longint unsigned cnt_stall_both = 64'd0;
    longint unsigned cnt_ex_busy = 64'd0;
    longint unsigned cnt_l0_hit = 64'd0;
    longint unsigned cnt_bram_load = 64'd0;
    longint unsigned cnt_retired = 64'd0;
    longint unsigned crc_completed_rounds = 64'd0;
    localparam logic [31:0] CRC_ROUND_DONE_PC = 32'h8000_066c;
    localparam real           CPU_FREQ_MHZ     = `SIM_CPU_FREQ_MHZ;
    localparam real           CPU_HALF_PERIOD_NS = 500.0 / CPU_FREQ_MHZ;
    localparam bit            HAS_EXPECTED_LED = `SIM_HAS_EXPECTED_LED;
    localparam [31:0]         EXPECTED_LED     = `SIM_EXPECTED_LED;
    localparam [31:0]         PASS_LED         = `SIM_PASS_LED;
    localparam [31:0]         FAIL_LED         = `SIM_FAIL_LED;
    localparam bit            TRACE_ENABLED    = `SIM_TRACE;
`ifdef COREMARK_VERIFY
    /* 输出加速到 1 MHz；输入任务仍按 shell 可消费的 1.1 ms 字节间隔发送。 */
    localparam integer SIM_UART_BAUD = 1000000;
`else
    localparam integer SIM_UART_BAUD = 9600;
`endif
    localparam time           STOP_NS          = `SIM_STOP_NS;
    localparam time           PROGRESS_NS      = `SIM_PROGRESS_NS;
    localparam int unsigned   PROGRESS_FD      = 32'h8000_0002;
    localparam int unsigned   PROGRESS_LINES   = 6;
    string trace_file = `SIM_TRACE_FILE;
    bit sim_done = 1'b0;
    bit progress_drawn = 1'b0;
    bit progress_last_valid = 1'b0;
    bit progress_last_led_written = 1'b0;
    bit progress_last_seg_written = 1'b0;
    logic [31:0] progress_last_led = 32'd0;
    logic [31:0] progress_last_seg = 32'd0;
    string stop_reason;
    integer init_idx;
    bit coremark_smoke_pass = 1'b0;

    always #(CPU_HALF_PERIOD_NS) clk = ~clk;
    always #10 cnt_clk = ~cnt_clk;

    mycpu dut (
        .cpu_rst     (rst),
        .cpu_clk     (clk),
        .irom_addr   (irom_addr),
        .irom_addr1  (irom_addr1),
        .irom_data   (irom_data),
        .irom_data1  (irom_data1),
        .perip_addr  (perip_addr),
        .perip_wen   (perip_wen),
        .perip_mask  (perip_mask),
        .perip_wdata (perip_wdata),
        .perip_rdata (perip_rdata)
    );
`ifdef COREMARK_VERIFY
    /* CoreMark 覆盖完整 64 KiB IROM；任何跳出代码区的 PC 都是硬失败。 */
    always @(posedge clk) begin
        if (!rst && !sim_done && (irom_addr[31:16] != 16'h8000)) begin
            $display("[UART-VERIFY] FAIL: PC left IROM: 0x%08X", irom_addr);
            finish_sim("coremark_bad_pc");
        end
    end
`endif

    /* UART 透传链路：tb(PC) <-> uart <-> twin_controller <-> uart_bridge <-> CPU */
    uart #(
        .CLK_FREQ  (50000000),
        .BAUD_RATE (SIM_UART_BAUD)
    ) uart_inst (
        .clk       (cnt_clk),
        .rst_n     (~rst),
        .rx        (uart_line_rx),
        .rx_data   (uart_rx_data),
        .rx_ready  (uart_rx_ready),
        .tx        (uart_line_tx),
        .tx_data   (uart_tx_data),
        .tx_start  (uart_tx_start),
        .tx_busy   (uart_tx_busy)
    );

    twin_controller twin_inst (
        .clk               (cnt_clk),
        .rst_n             (~rst),
        .rx_ready          (uart_rx_ready),
        .rx_data           (uart_rx_data),
        .tx_start          (uart_tx_start),
        .tx_data           (uart_tx_data),
        .tx_busy           (uart_tx_busy),
        .sw                (twin_sw),
        .key               (twin_key),
        .seg               (twin_seg),
        .led               (twin_led),
        .cpu_uart_tx_data  (cpu_uart_tx_data),
        .cpu_uart_tx_start (cpu_uart_tx_start),
        .cpu_uart_rx_data  (cpu_uart_rx_data),
        .cpu_uart_rx_valid (cpu_uart_rx_valid),
        .passthrough       (twin_passthrough),
        .passthrough_req   (twin_passthrough_req)
    );

    uart_bridge bridge_inst (
        .clk            (clk),
        .cnt_clk        (cnt_clk),
        .rst            (rst),
        .uart_addr      (perip_addr[3:2]),
        .uart_wdata     (perip_wdata[7:0]),
        .uart_wen       (perip_wen && perip_addr == UART_DATA_ADDR),
        .uart_ren       (~perip_wen && perip_addr == UART_DATA_ADDR),
        .uart_rdata     (uart_rdata),
        .uart_tx_data   (cpu_uart_tx_data),
        .uart_tx_start  (cpu_uart_tx_start),
        .uart_tx_busy   (uart_tx_busy),
        .uart_rx_data   (cpu_uart_rx_data),
        .uart_rx_ready  (cpu_uart_rx_valid),
        .passthrough    (twin_passthrough),
        .ps_wen         (perip_wen && perip_addr == UART_STATUS_ADDR),
        .passthrough_req(twin_passthrough_req)
    );

    initial begin
        if (TRACE_ENABLED) begin
            $dumpfile(trace_file);
            $dumpvars(0, tb_cpu_only);
            $display(" trace             : %s", trace_file);
        end
        for (init_idx = 0; init_idx < 16384; init_idx = init_idx + 1)
            irom[init_idx] = 32'd0;
        for (init_idx = 0; init_idx < 65536; init_idx = init_idx + 1)
            bram[init_idx] = 32'd0;
        $readmemh("build/irom.mem", irom);
        $readmemh("build/bram.mem", bram);
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    always_ff @(posedge clk) begin
        // 与 blk_mem_gen IROM 的一拍同步读一致，高位 PC 仍按 student_top 忽略。
        irom_data  <= irom[irom_addr[15:2]];
        irom_data1 <= irom[irom_addr1[15:2]];
    end

    function automatic [31:0] select_load_word(input [31:0] word, input [1:0] mask, input [1:0] offset);
        begin
            case (mask)
                2'b00: begin
                    case (offset)
                        2'b00: select_load_word = {24'b0, word[7:0]};
                        2'b01: select_load_word = {24'b0, word[15:8]};
                        2'b10: select_load_word = {24'b0, word[23:16]};
                        default: select_load_word = {24'b0, word[31:24]};
                    endcase
                end
                2'b01: select_load_word = offset[1] ? {16'b0, word[31:16]} : {16'b0, word[15:0]};
                2'b10: select_load_word = word;
                default: select_load_word = 32'd0;
            endcase
        end
    endfunction

    function automatic [31:0] merge_store_word(
        input [31:0] old_word,
        input [31:0] write_word,
        input [1:0] mask,
        input [1:0] offset
    );
        begin
            case (mask)
                2'b10: merge_store_word = write_word;
                2'b01: merge_store_word = offset[1] ? {write_word[15:0], old_word[15:0]} :
                                                     {old_word[31:16], write_word[15:0]};
                2'b00: begin
                    case (offset)
                        2'b00: merge_store_word = {old_word[31:8], write_word[7:0]};
                        2'b01: merge_store_word = {old_word[31:16], write_word[7:0], old_word[7:0]};
                        2'b10: merge_store_word = {old_word[31:24], write_word[7:0], old_word[15:0]};
                        default: merge_store_word = {write_word[7:0], old_word[23:0]};
                    endcase
                end
                default: merge_store_word = write_word;
            endcase
        end
    endfunction

    always_comb begin
        perip_rdata = 32'd0;
        if (bram_resp_valid) begin
            perip_rdata = bram_rdata_q;
        end else if (!perip_wen) begin
            case (perip_addr)
                SW0_ADDR: perip_rdata = twin_sw[31:0];
                SW1_ADDR: perip_rdata = twin_sw[63:32];
                KEY_ADDR: perip_rdata = {24'd0, twin_key};
                SEG_ADDR: perip_rdata = seg_wdata;
                CNT_ADDR: perip_rdata = cnt_ms;
                UART_DATA_ADDR:   perip_rdata = uart_rdata;
                UART_STATUS_ADDR: perip_rdata = uart_rdata;
                default: perip_rdata = 32'd0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            virtual_led <= 32'hxxxx_xxxx;
            led_written <= 1'b0;
            seg_wdata <= 32'h3700_0000;
            seg_written <= 1'b0;
            cnt_enable <= 1'b0;
            cnt_started <= 1'b0;
            bram_rdata_q <= 32'd0;
            bram_resp_valid <= 1'b0;
        end else begin
            bram_resp_valid <= !perip_wen && (perip_addr >= BRAM_BASE && perip_addr <= BRAM_END);
            if (!perip_wen && (perip_addr >= BRAM_BASE && perip_addr <= BRAM_END)) begin
                bram_rdata_q <= select_load_word(bram[(perip_addr - BRAM_BASE) >> 2], perip_mask, perip_addr[1:0]);
            end
            if (perip_wen) begin
                if (perip_addr >= BRAM_BASE && perip_addr <= BRAM_END) begin
                    bram[(perip_addr - BRAM_BASE) >> 2] <= merge_store_word(
                        bram[(perip_addr - BRAM_BASE) >> 2],
                        perip_wdata,
                        perip_mask,
                        perip_addr[1:0]
                    );
                end else begin
                    case (perip_addr)
                        LED_ADDR: begin
                            virtual_led <= perip_wdata;
                            led_written <= 1'b1;
                        end
                        SEG_ADDR: begin
                            seg_wdata <= perip_wdata;
                            seg_written <= 1'b1;
                        end
                        CNT_ADDR: begin
                            if (perip_wdata == 32'h8000_0000) begin
                                cnt_enable <= 1'b1;
                                if (!cnt_started) begin
                                    cnt_started <= 1'b1;
                                    cnt_start_time <= $time;
                                end
                            end else if (perip_wdata == 32'hffff_ffff) begin
                                cnt_enable <= 1'b0;
                            end
                        end
                    endcase
                end
            end
        end
    end

    always_ff @(posedge cnt_clk) begin
        if (rst) begin
            cnt_ms <= 32'd0;
            cnt_1ms <= 16'd0;
        end else if (cnt_enable) begin
            if (cnt_1ms == 16'd49999) begin
                cnt_1ms <= 16'd0;
                cnt_ms <= cnt_ms + 1;
            end else begin
                cnt_1ms <= cnt_1ms + 1;
            end
        end else begin
            cnt_1ms <= 16'd0;
        end
    end

    /* ---- UART 行为模型；COREMARK_VERIFY 使用高速仿真串口 ---- */
    localparam time UART_BIT_NS = (SIM_UART_BAUD == 9600) ? 104160 : 1000;

    task automatic uart_tx_byte(input [7:0] data);
        integer bit_idx;
        begin
            uart_line_rx = 1'b0;             // start
            #(UART_BIT_NS);
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                uart_line_rx = data[bit_idx]; // LSB first
                #(UART_BIT_NS);
            end
            uart_line_rx = 1'b1;             // stop
            #(UART_BIT_NS);
`ifdef COREMARK_VERIFY
            /* finsh 空闲读会休眠 1 ms，RX bridge 只存一个字节；不能突发注入。 */
            #(1_100_000);
`endif
        end
    endtask

    always begin : uart_tx_capture
        logic [7:0] cap_byte;
        integer bit_idx;
        uart_line_rx = 1'b1;
        forever begin
            @(negedge uart_line_tx);         // start bit
            #(UART_BIT_NS * 3 / 2);          // 采样点：位中心
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin
                cap_byte[bit_idx] = uart_line_tx;
                #(UART_BIT_NS);
            end
            /* 不再等待 stop 位：连续发送周期为 10 位，若再等 1 位（共 10.5 位）
             * 会错过下一字节的 start 沿，导致从数据位下降沿触发、采样错位 */
            uart_cap_queue[uart_cap_qlen] = cap_byte;
            uart_cap_qlen = uart_cap_qlen + 1;
`ifndef COREMARK_VERIFY
            $display("[UART-TX] t=%0t 0x%02X %c", $time, cap_byte, (cap_byte >= 8'h20 && cap_byte < 8'h7F) ? cap_byte : 8'h2E);
`endif
        end
    end

    function automatic bit uart_queue_has_str(string s);
        integer i, j;
        bit found;
        begin
            found = 1'b0;
            for (i = 0; i <= uart_cap_qlen - s.len() && !found; i = i + 1) begin
                found = 1'b1;
                for (j = 0; j < s.len(); j = j + 1) begin
                    if (uart_cap_queue[i + j] != s[j]) begin
                        found = 1'b0;
                    end
                end
            end
            uart_queue_has_str = found;
        end
    endfunction

    function automatic bit uart_queue_has_str_from(string s, integer start_idx);
        integer i, j;
        bit found;
        begin
            found = 1'b0;
            for (i = start_idx; i <= uart_cap_qlen - s.len() && !found; i = i + 1) begin
                found = 1'b1;
                for (j = 0; j < s.len(); j = j + 1) begin
                    if (uart_cap_queue[i + j] != s[j])
                        found = 1'b0;
                end
            end
            uart_queue_has_str_from = found;
        end
    endfunction

    initial begin : uart_verify
        integer coremark_output_start;
        /* CPU 启动时主动请求透传（board.c rt_hw_board_init 写 UART_STATUS）：
         * 等待透传建立（twin 进 PASSTHROUGH）与 finsh banner 输出完成。 */
`ifdef COREMARK_VERIFY
        #(15_000_000);
`else
        #(200_000_000);
`endif
        if (twin_inst.current_state == 2) begin
            $display("[UART-VERIFY] passthrough established by CPU (state=%0d)", twin_inst.current_state);
        end else begin
            $display("[UART-VERIFY] FAIL: passthrough not established (state=%0d)", twin_inst.current_state);
            finish_sim("uart_assert_fail");
        end
        $display("[UART-VERIFY] inject 'help\\r'");
        uart_tx_byte("h");
        uart_tx_byte("e");
        uart_tx_byte("l");
        uart_tx_byte("p");
        uart_tx_byte(8'h0D);
`ifdef COREMARK_VERIFY
        #(6_000_000);
`else
        #(60_000_000);
`endif
        if (uart_queue_has_str("version")) begin
            $display("[UART-VERIFY] shell verification passed (qlen=%0d)", uart_cap_qlen);
            /* help 输出约 386 字节，9600 baud 下需约 0.4 s；先等 shell
             * 完成输出并回到提示符，避免 RX 单字节桥在忙打印时丢整行。 */
`ifdef COREMARK_VERIFY
            #(40_000_000);
`else
            #(400_000_000);
`endif
        end else begin
            $display("[UART-VERIFY] FAIL: help output missing 'version' (qlen=%0d)", uart_cap_qlen);
            finish_sim("uart_assert_fail");
        end
`ifdef COREMARK_VERIFY
        /* TOTAL_DATA_SIZE=2000 由三个算法均分为 666 bytes：官方 2K 档。
         * 24 次仅用于 RTL smoke test，必然触发官方“至少 10 秒”提示；
         * 正式跑分使用裸 coremark 的 5000 次默认值。 */
        coremark_output_start = uart_cap_qlen;
        $display("[UART-VERIFY] inject 'coremark 0 0 0x66 24\\r'");
        uart_tx_byte("c");
        uart_tx_byte("o");
        uart_tx_byte("r");
        uart_tx_byte("e");
        uart_tx_byte("m");
        uart_tx_byte("a");
        uart_tx_byte("r");
        uart_tx_byte("k");
        uart_tx_byte(" ");
        uart_tx_byte("0");
        uart_tx_byte(" ");
        uart_tx_byte("0");
        uart_tx_byte(" ");
        uart_tx_byte("0");
        uart_tx_byte("x");
        uart_tx_byte("6");
        uart_tx_byte("6");
        uart_tx_byte(" ");
        uart_tx_byte("2");
        uart_tx_byte("4");
        uart_tx_byte(8'h0D);
        #(180_000_000);
        if (uart_queue_has_str_from("2K performance run parameters", coremark_output_start) &&
            uart_queue_has_str_from("[0]crclist       : 0xe714", coremark_output_start) &&
            uart_queue_has_str_from("[0]crcmatrix     : 0x1fd7", coremark_output_start) &&
            uart_queue_has_str_from("[0]crcstate      : 0x8e3a", coremark_output_start) &&
            uart_queue_has_str_from("ERROR! Must execute for at least 10 secs", coremark_output_start) &&
            uart_queue_has_str_from("msh >", coremark_output_start) &&
            !uart_queue_has_str_from("ERROR! list crc", coremark_output_start) &&
            !uart_queue_has_str_from("ERROR! matrix crc", coremark_output_start) &&
            !uart_queue_has_str_from("ERROR! state crc", coremark_output_start)) begin
            coremark_smoke_pass = 1'b1;
            $display("[UART-VERIFY] CoreMark CRC smoke passed and returned to msh (qlen=%0d)", uart_cap_qlen);
        end else begin
            $display("[UART-VERIFY] FAIL: coremark output mismatch (qlen=%0d)", uart_cap_qlen);
            finish_sim("uart_assert_fail");
        end
`endif
        $display("[UART-VERIFY] inject 0xCA (exit passthrough)");
        uart_tx_byte(8'hCA);
        #(10_000_000);
        $display("[UART-VERIFY] inject 0x80 (readback)");
        uart_tx_byte(8'h80);
        #(30_000_000);
        if (uart_cap_qlen >= 18) begin
            $display("[UART-VERIFY] readback verification passed (qlen=%0d)", uart_cap_qlen);
`ifdef COREMARK_VERIFY
            finish_sim("coremark_smoke");
`endif
        end else begin
            $display("[UART-VERIFY] FAIL: readback too short (qlen=%0d)", uart_cap_qlen);
            finish_sim("uart_assert_fail");
        end
    end

    /* twin 回读内容用确定值（避免 x 传播到 UART 线） */
    always_ff @(posedge clk) begin
        if (led_written)
            twin_led <= virtual_led;
        if (seg_written)
            twin_seg <= {8'd0, seg_wdata};
    end

    function automatic [15:0] bcd4(input [31:0] value);
        integer v;
        begin
            v = value % 10000;
            bcd4 = {4'(((v / 1000) % 10) & 15),
                    4'(((v / 100) % 10) & 15),
                    4'(((v / 10) % 10) & 15),
                    4'((v % 10) & 15)};
        end
    endfunction

    task automatic clear_progress_line;
        integer line_idx;
        begin
            if (PROGRESS_NS > 0 && progress_drawn) begin
                $fwrite(PROGRESS_FD, "\r\033[2K");
                for (line_idx = 1; line_idx < PROGRESS_LINES; line_idx = line_idx + 1)
                    $fwrite(PROGRESS_FD, "\033[1A\r\033[2K");
                $fwrite(PROGRESS_FD, "\r");
                $fflush();
                progress_drawn = 1'b0;
            end
        end
    endtask

    task automatic print_progress_led_graphic(input [31:0] led, input bit written);
        integer row;
        integer col;
        integer bit_idx;
        begin
            for (row = 3; row >= 0; row = row - 1) begin
                if (row == 3)
                    $fwrite(PROGRESS_FD, " led_graphic       : ");
                else
                    $fwrite(PROGRESS_FD, "                     ");

                if (written) begin
                    for (col = 7; col >= 0; col = col - 1) begin
                        bit_idx = row * 8 + col;
                        $fwrite(PROGRESS_FD, "%s", led[bit_idx] ? "#" : ".");
                    end
                end else if (row == 3) begin
                    $fwrite(PROGRESS_FD, "not written");
                end
                $fwrite(PROGRESS_FD, "\n");
            end
        end
    endtask

    task automatic print_progress_display(
        input time elapsed_ns,
        input integer percent_whole,
        input integer percent_tenth
    );
        begin
            clear_progress_line();
            print_progress_led_graphic(virtual_led, led_written);
            if (seg_written)
                $fwrite(PROGRESS_FD, " seg_wdata         : 0x%08X\n", seg_wdata);
            else
                $fwrite(PROGRESS_FD, " seg_wdata         : 0x%08X (not written)\n", seg_wdata);
            $fwrite(PROGRESS_FD, "[progress] sim=%0dns / %0dns (%0d.%0d%%)",
                    elapsed_ns, STOP_NS, percent_whole, percent_tenth);
            $fflush();
            progress_drawn = 1'b1;
        end
    endtask

    task automatic update_progress_line(
        input time elapsed_ns,
        input integer percent_whole,
        input integer percent_tenth
    );
        begin
            $fwrite(PROGRESS_FD, "\r\033[2K[progress] sim=%0dns / %0dns (%0d.%0d%%)",
                    elapsed_ns, STOP_NS, percent_whole, percent_tenth);
            $fflush();
        end
    endtask

    task automatic print_led_graphic(input [31:0] led);
        integer row;
        integer col;
        integer bit_idx;
        begin
            for (row = 3; row >= 0; row = row - 1) begin
                if (row == 3)
                    $write(" led_graphic       : ");
                else
                    $write("                     ");
                for (col = 7; col >= 0; col = col - 1) begin
                    bit_idx = row * 8 + col;
                    $write("%s", led[bit_idx] ? "#" : ".");
                end
                $write("\n");
            end
        end
    endtask

    task automatic print_crc_snapshot(input longint unsigned completed_rounds);
        begin
            clear_progress_line();
            $display(">>> [CRC_SNAPSHOT] rounds=%0d", completed_rounds);
            $display(" cnt_ms            : %0d", cnt_ms);
            $display(" cycles            : %0d", cycles);
            $display(" writeback (reg_file)    : %0d", cnt_writeback);
            $display(" slot1 writeback   : %0d", cnt_slot1_writeback);
            $display(" stores            : %0d", cnt_store);
            $display(" taken branches    : %0d", cnt_branch);
            $display(" dual issue packets: %0d", cnt_dual_issue);
            $display(" front stall cycles: %0d", cnt_stall_front);
            $display(" load/use stalls   : %0d", cnt_stall_hazard);
            $display(" load/use EX stalls: %0d", cnt_load_use_ex);
            $display(" load/use MEM stalls: %0d", cnt_load_use_mem);
            $display(" hazard+EX busy    : %0d", cnt_stall_both);
            $display(" ex busy cycles    : %0d", cnt_ex_busy);
            $display(" L0 load hits      : %0d", cnt_l0_hit);
            $display(" BRAM loads        : %0d", cnt_bram_load);
            $display(" retired inst      : %0d", cnt_retired);
        end
    endtask

    task automatic finish_sim(input string reason);
        bit result_ok;
        begin
            if (!sim_done) begin
                sim_done = 1'b1;
                stop_reason = reason;
`ifdef COREMARK_VERIFY
                result_ok = coremark_smoke_pass && (reason == "coremark_smoke");
`else
                result_ok = (virtual_led != FAIL_LED) &&
                            ((HAS_EXPECTED_LED && virtual_led == EXPECTED_LED) ||
                             (!HAS_EXPECTED_LED && virtual_led == PASS_LED));
`endif
                clear_progress_line();
                if (result_ok)
                    $display(">>> [PASS] final state matches enabled checks");
                else
                    $display(">>> [FAIL] final state mismatch");
`ifdef COREMARK_VERIFY
                $display(" coremark_smoke    : %s", coremark_smoke_pass ? "pass" : "fail");
`else
                if (HAS_EXPECTED_LED)
                    $display(" expected_led      : 0x%08X (%s)", EXPECTED_LED, result_ok ? "match" : "mismatch");
`endif
                $display(" pass_led          : 0x%08X", PASS_LED);
                $display(" fail_led          : 0x%08X", FAIL_LED);
                $display(" stop_reason       : %s", stop_reason);
                if (HAS_EXPECTED_LED)
                    $display(" virtual_led       : 0x%08X", virtual_led);
                else
                    $display(" virtual_led       : 0x%08X (unchecked)", virtual_led);
                $display(" led_written       : %0d", led_written);
                if (led_written) print_led_graphic(virtual_led);
                $display(" seg_wdata         : 0x%08X", seg_wdata);
                $display(" seg_written       : %0d", seg_written);
                $display(" cnt_ms            : %0d", cnt_ms);
                $display(" cnt_start_ns      : %0d", cnt_start_time);
                $display(" cycles            : %0d", cycles);
                $display(" cpu_freq_mhz      : %0.3f", CPU_FREQ_MHZ);
                $display(" cpu_period_ns     : %0.6f", CPU_HALF_PERIOD_NS * 2.0);
                $display(" writeback (reg_file)    : %0d", cnt_writeback);
                $display(" slot1 writeback   : %0d", cnt_slot1_writeback);
                $display(" stores            : %0d", cnt_store);
                $display(" taken branches    : %0d", cnt_branch);
                $display(" dual issue packets: %0d", cnt_dual_issue);
                $display(" front stall cycles: %0d", cnt_stall_front);
                $display(" load/use stalls   : %0d", cnt_stall_hazard);
                $display(" load/use EX stalls: %0d", cnt_load_use_ex);
                $display(" load/use MEM stalls: %0d", cnt_load_use_mem);
                $display(" hazard+EX busy    : %0d", cnt_stall_both);
                $display(" ex busy cycles    : %0d", cnt_ex_busy);
                $display(" L0 load hits      : %0d", cnt_l0_hit);
                $display(" BRAM loads        : %0d", cnt_bram_load);
                if (cnt_bram_load > 0)
                    $display(" L0 hit rate       : %0.3f%%",
                             100.0 * cnt_l0_hit / cnt_bram_load);
                $display(" retired inst      : %0d", cnt_retired);
                if (cnt_retired > 0) begin
                    $display(" CPI               : %0.3f", cycles * 1.0 / cnt_retired);
                    $display(" MIPS              : %0.3f", CPU_FREQ_MHZ * cnt_retired / cycles);
                end
                $display(" pc                : 0x%08X", irom_addr);
                $display(" sim_time_ns       : %0d", $time);
                $display("==================================================");
                $finish;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            crc_completed_rounds <= 64'd0;
        end else begin
            if ((dut.EX_valid && dut.EX_pc == CRC_ROUND_DONE_PC) ||
                (dut.EX_S1_valid && dut.EX_S1_pc == CRC_ROUND_DONE_PC)) begin
                crc_completed_rounds <= crc_completed_rounds + 1;
                if ((crc_completed_rounds + 1 == 8) ||
                    (crc_completed_rounds + 1 == 16)) begin
                    print_crc_snapshot(crc_completed_rounds + 1);
                end
            end
            cycles <= cycles + 1;
            cnt_writeback <= cnt_writeback +
                             ((dut.rf_inst.wen && dut.rf_inst.waddr != 5'd0) ? 1 : 0) +
                             ((dut.rf_inst.wen2 && dut.rf_inst.waddr2 != 5'd0) ? 1 : 0);
            if (dut.rf_inst.wen2 && dut.rf_inst.waddr2 != 5'd0)
                cnt_slot1_writeback <= cnt_slot1_writeback + 1;
            if (perip_wen)
                cnt_store <= cnt_store + 1;
            if (dut.BranchTaken)
                cnt_branch <= cnt_branch + 1;
            if (dut.IF_issue_dual && !dut.Stall_Front)
                cnt_dual_issue <= cnt_dual_issue + 1;
            if (dut.Stall_Front)
                cnt_stall_front <= cnt_stall_front + 1;
            if (dut.Stall_Hazard)
                cnt_stall_hazard <= cnt_stall_hazard + 1;
            if (dut.LoadUseEX)
                cnt_load_use_ex <= cnt_load_use_ex + 1;
            if (dut.LoadUseMEM)
                cnt_load_use_mem <= cnt_load_use_mem + 1;
            if (dut.Stall_Hazard && dut.EX_any_busy)
                cnt_stall_both <= cnt_stall_both + 1;
            if (dut.EX_any_busy)
                cnt_ex_busy <= cnt_ex_busy + 1;
            cnt_l0_hit <= cnt_l0_hit +
                          ((dut.MEM_valid && dut.MEM_cache_hit0) ? 1 : 0) +
                          ((dut.MEM_S1_valid && dut.MEM_cache_hit1) ? 1 : 0);
            cnt_bram_load <= cnt_bram_load +
                             ((dut.MEM_valid && dut.MEM_MemRead &&
                               dut.MEM_bram_access) ? 1 : 0) +
                             ((dut.MEM_S1_valid && dut.MEM_S1_MemRead &&
                               dut.MEM_S1_bram_access) ? 1 : 0);

            // 若完成 store 位于 slot0，同包 slot1 在程序顺序上更年轻，不纳入截止统计。
            if (led_written &&
                ((HAS_EXPECTED_LED && virtual_led == EXPECTED_LED) ||
                 virtual_led == PASS_LED || virtual_led == FAIL_LED) &&
                dut.WB_retire_store0) begin
                cnt_retired <= cnt_retired + (dut.WB_retire_valid0 ? 1 : 0);
            end else begin
                cnt_retired <= cnt_retired +
                               (dut.WB_retire_valid0 ? 1 : 0) +
                               (dut.WB_retire_valid1 ? 1 : 0);
            end
        end
    end

    always @(negedge clk) begin
        if (!rst && led_written &&
            ((HAS_EXPECTED_LED && virtual_led == EXPECTED_LED) ||
             virtual_led == PASS_LED ||
             virtual_led == FAIL_LED) &&
            (dut.WB_retire_store0 || dut.WB_retire_store1)) begin
            finish_sim("led");
        end
    end

    initial begin
        $display("==================================================");
        $display(" CPU-only Simulation");
        $display("==================================================");
    end

    initial begin : progress_reporter
        time elapsed_ns;
        integer percent_whole;
        integer percent_tenth;
        bit display_changed;
        if (PROGRESS_NS > 0) begin
            forever begin
                #(PROGRESS_NS);
                elapsed_ns = $time;
                if (elapsed_ns >= STOP_NS || sim_done)
                    disable progress_reporter;
                percent_whole = integer'((elapsed_ns * 100) / STOP_NS);
                percent_tenth = integer'((elapsed_ns * 1000) / STOP_NS) % 10;
                display_changed = !progress_last_valid ||
                                  (progress_last_led_written != led_written) ||
                                  (progress_last_seg_written != seg_written) ||
                                  (led_written && (progress_last_led !== virtual_led)) ||
                                  (seg_written && (progress_last_seg !== seg_wdata));
                if (display_changed || !progress_drawn) begin
                    print_progress_display(elapsed_ns, percent_whole, percent_tenth);
                    progress_last_valid = 1'b1;
                    progress_last_led_written = led_written;
                    progress_last_seg_written = seg_written;
                    progress_last_led = virtual_led;
                    progress_last_seg = seg_wdata;
                end else begin
                    update_progress_line(elapsed_ns, percent_whole, percent_tenth);
                end
            end
        end
    end

    initial begin : timeout_stop
        #(STOP_NS);
        finish_sim("timeout");
    end
endmodule
