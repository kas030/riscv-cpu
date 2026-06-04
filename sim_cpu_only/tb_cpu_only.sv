`timescale 1ns / 1ps
`include "sim_config.svh"

module tb_cpu_only;
    localparam DRAM_BASE = 32'h8010_0000;
    localparam DRAM_END  = 32'h8013_FFFF;
    localparam SW0_ADDR  = 32'h8020_0000;
    localparam SW1_ADDR  = 32'h8020_0004;
    localparam KEY_ADDR  = 32'h8020_0010;
    localparam SEG_ADDR  = 32'h8020_0020;
    localparam LED_ADDR  = 32'h8020_0040;
    localparam CNT_ADDR  = 32'h8020_0050;

    logic clk = 1'b0;
    logic cnt_clk = 1'b0;
    logic rst = 1'b1;

    logic [31:0] irom_addr;
    logic [31:0] irom_data;
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
    logic [31:0] irom [0:4095];
    logic [31:0] dram [0:65535];
    logic [31:0] dram_rdata_q;
    logic        dram_resp_valid;

    longint unsigned cycles = 64'd0;
    longint unsigned cnt_writeback = 64'd0;
    longint unsigned cnt_store = 64'd0;
    longint unsigned cnt_branch = 64'd0;
    longint unsigned approx_inst;
    localparam bit            HAS_EXPECTED_LED = `SIM_HAS_EXPECTED_LED;
    localparam [31:0]         EXPECTED_LED     = `SIM_EXPECTED_LED;
    localparam [31:0]         PASS_LED         = `SIM_PASS_LED;
    localparam [31:0]         FAIL_LED         = `SIM_FAIL_LED;
    localparam bit            TRACE_ENABLED    = `SIM_TRACE;
    localparam time           STOP_NS          = `SIM_STOP_NS;
    localparam time           PROGRESS_NS      = `SIM_PROGRESS_NS;
    localparam int unsigned   PROGRESS_FD      = 32'h8000_0002;
    string trace_file = `SIM_TRACE_FILE;
    bit sim_done = 1'b0;
    string stop_reason;
    integer init_idx;

    always #3.333 clk = ~clk;
    always #10 cnt_clk = ~cnt_clk;

    mycpu dut (
        .cpu_rst     (rst),
        .cpu_clk     (clk),
        .irom_addr   (irom_addr),
        .irom_data   (irom_data),
        .perip_addr  (perip_addr),
        .perip_wen   (perip_wen),
        .perip_mask  (perip_mask),
        .perip_wdata (perip_wdata),
        .perip_rdata (perip_rdata)
    );

    initial begin
        if (TRACE_ENABLED) begin
            $dumpfile(trace_file);
            $dumpvars(0, tb_cpu_only);
            $display(" trace             : %s", trace_file);
        end
        for (init_idx = 0; init_idx < 4096; init_idx = init_idx + 1)
            irom[init_idx] = 32'd0;
        for (init_idx = 0; init_idx < 65536; init_idx = init_idx + 1)
            dram[init_idx] = 32'd0;
        $readmemh("build/irom.mem", irom);
        $readmemh("build/dram.mem", dram);
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    always_comb begin
        // student_top.sv 使用 pc[13:2] 访问 IROM，这里保持同样的高位忽略语义。
        irom_data = irom[irom_addr[13:2]];
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
        if (dram_resp_valid) begin
            perip_rdata = dram_rdata_q;
        end else if (!perip_wen) begin
            case (perip_addr)
                SW0_ADDR: perip_rdata = 32'd0;
                SW1_ADDR: perip_rdata = 32'd0;
                KEY_ADDR: perip_rdata = 32'd0;
                SEG_ADDR: perip_rdata = seg_wdata;
                CNT_ADDR: perip_rdata = cnt_ms;
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
            dram_rdata_q <= 32'd0;
            dram_resp_valid <= 1'b0;
        end else begin
            dram_resp_valid <= !perip_wen && (perip_addr >= DRAM_BASE && perip_addr < DRAM_END);
            if (!perip_wen && (perip_addr >= DRAM_BASE && perip_addr < DRAM_END)) begin
                dram_rdata_q <= select_load_word(dram[(perip_addr - DRAM_BASE) >> 2], perip_mask, perip_addr[1:0]);
            end
            if (perip_wen) begin
                if (perip_addr >= DRAM_BASE && perip_addr < DRAM_END) begin
                    dram[(perip_addr - DRAM_BASE) >> 2] <= merge_store_word(
                        dram[(perip_addr - DRAM_BASE) >> 2],
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
        begin
            if (PROGRESS_NS > 0) begin
                $fwrite(PROGRESS_FD, "\r                                                                                \r");
                $fflush();
            end
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

    task automatic finish_sim(input string reason);
        bit led_ok;
        begin
            if (!sim_done) begin
                sim_done = 1'b1;
                stop_reason = reason;
                approx_inst = cnt_writeback + cnt_store + cnt_branch;
                led_ok = (virtual_led != FAIL_LED) &&
                         ((HAS_EXPECTED_LED && virtual_led == EXPECTED_LED) ||
                          (!HAS_EXPECTED_LED && virtual_led == PASS_LED));
                clear_progress_line();
                if (led_ok)
                    $display(">>> [PASS] final state matches enabled checks");
                else
                    $display(">>> [FAIL] final state mismatch");
                if (HAS_EXPECTED_LED)
                    $display(" expected_led      : 0x%08X (%s)", EXPECTED_LED, led_ok ? "match" : "mismatch");
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
                $display(" writeback (reg_file)    : %0d", cnt_writeback);
                $display(" stores            : %0d", cnt_store);
                $display(" taken branches    : %0d", cnt_branch);
                $display(" approx total inst : %0d", approx_inst);
                if (approx_inst > 0)
                    $display(" CPI (approx)      : %0.3f", cycles * 1.0 / approx_inst);
                $display(" pc                : 0x%08X", irom_addr);
                $display(" sim_time_ns       : %0d", $time);
                $display("==================================================");
                $finish;
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if (dut.rf_inst.wen && dut.rf_inst.waddr != 5'd0)
                cnt_writeback <= cnt_writeback + 1;
            if (perip_wen)
                cnt_store <= cnt_store + 1;
            if (dut.BranchTaken)
                cnt_branch <= cnt_branch + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && led_written &&
            ((HAS_EXPECTED_LED && virtual_led == EXPECTED_LED) ||
             virtual_led == PASS_LED ||
             virtual_led == FAIL_LED)) begin
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
        if (PROGRESS_NS > 0) begin
            forever begin
                #(PROGRESS_NS);
                elapsed_ns = $time;
                if (elapsed_ns >= STOP_NS || sim_done)
                    disable progress_reporter;
                percent_whole = integer'((elapsed_ns * 100) / STOP_NS);
                percent_tenth = integer'((elapsed_ns * 1000) / STOP_NS) % 10;
                $fwrite(PROGRESS_FD, "\r[progress] sim=%0dns / %0dns (%0d.%0d%%)",
                        elapsed_ns, STOP_NS, percent_whole, percent_tenth);
                $fflush();
            end
        end
    end

    initial begin : timeout_stop
        #(STOP_NS);
        finish_sim("timeout");
    end
endmodule
