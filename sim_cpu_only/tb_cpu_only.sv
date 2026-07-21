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
    logic [31:0] irom [0:4095];
    logic [31:0] bram [0:65535];
    logic [31:0] bram_rdata_q;
    logic        bram_resp_valid;

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
    logic [63:0] retire_digest = 64'hcbf29ce484222325;
    logic [63:0] store_digest = 64'hcbf29ce484222325;
    logic [63:0] register_signature, csr_signature;
    logic [63:0] retire_digest_next, store_digest_next;
    localparam real           CPU_FREQ_MHZ     = `SIM_CPU_FREQ_MHZ;
    localparam real           CPU_HALF_PERIOD_NS = 500.0 / CPU_FREQ_MHZ;
    localparam bit            HAS_EXPECTED_LED = `SIM_HAS_EXPECTED_LED;
    localparam [31:0]         EXPECTED_LED     = `SIM_EXPECTED_LED;
    localparam [31:0]         PASS_LED         = `SIM_PASS_LED;
    localparam [31:0]         FAIL_LED         = `SIM_FAIL_LED;
    localparam bit            TRACE_ENABLED    = `SIM_TRACE;
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
    integer signature_idx;

    function automatic [63:0] signature_mix(input [63:0] state, input [31:0] value);
        signature_mix = (state ^ {32'd0, value}) * 64'h00000100000001b3;
    endfunction

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

    initial begin
        if (TRACE_ENABLED) begin
            $dumpfile(trace_file);
            $dumpvars(0, tb_cpu_only);
            $display(" trace             : %s", trace_file);
        end
        for (init_idx = 0; init_idx < 4096; init_idx = init_idx + 1)
            irom[init_idx] = 32'd0;
        for (init_idx = 0; init_idx < 65536; init_idx = init_idx + 1)
            bram[init_idx] = 32'd0;
        $readmemh("build/irom.mem", irom);
        $readmemh("build/bram.mem", bram);
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    always_comb begin
        // student_top.sv 使用 pc[13:2] 访问 IROM，这里保持同样的高位忽略语义。
        irom_data = irom[irom_addr[13:2]];
        irom_data1 = irom[irom_addr1[13:2]];
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

    always_comb begin
        register_signature = 64'hcbf29ce484222325;
        for (signature_idx = 0; signature_idx < 32; signature_idx = signature_idx + 1)
            register_signature = signature_mix(register_signature, dut.rf_inst.xreg[signature_idx]);
        csr_signature = 64'hcbf29ce484222325;
        csr_signature = signature_mix(csr_signature, dut.u_ex_stage.u_csr_file.mstatus);
        csr_signature = signature_mix(csr_signature, dut.u_ex_stage.u_csr_file.mtvec);
        csr_signature = signature_mix(csr_signature, dut.u_ex_stage.u_csr_file.mscratch);
        csr_signature = signature_mix(csr_signature, dut.u_ex_stage.u_csr_file.mepc);
        csr_signature = signature_mix(csr_signature, dut.u_ex_stage.u_csr_file.mcause);

        retire_digest_next = retire_digest;
        if (dut.WB_retire_valid0) begin
            retire_digest_next = signature_mix(retire_digest_next, dut.WB_pcadd4 - 32'd4);
            retire_digest_next = signature_mix(retire_digest_next, {26'd0, dut.WB_RegWrite, dut.WB_rd});
            retire_digest_next = signature_mix(retire_digest_next, dut.WB_wdata);
        end
        if (dut.WB_retire_valid1) begin
            retire_digest_next = signature_mix(retire_digest_next, dut.WB_S1_pcadd4 - 32'd4);
            retire_digest_next = signature_mix(retire_digest_next, {26'd0, dut.WB_S1_RegWrite, dut.WB_S1_rd});
            retire_digest_next = signature_mix(retire_digest_next, dut.WB_S1_wdata);
        end
        store_digest_next = store_digest;
        if (perip_wen) begin
            store_digest_next = signature_mix(store_digest_next, perip_addr);
            store_digest_next = signature_mix(store_digest_next, {30'd0, perip_mask});
            store_digest_next = signature_mix(store_digest_next, perip_wdata);
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            retire_digest <= 64'hcbf29ce484222325;
            store_digest <= 64'hcbf29ce484222325;
        end else begin
            retire_digest <= retire_digest_next;
            store_digest <= store_digest_next;
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

    task automatic finish_sim(input string reason);
        bit led_ok;
        begin
            if (!sim_done) begin
                sim_done = 1'b1;
                stop_reason = reason;
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
                $display(" retire digest     : %016X", retire_digest);
                $display(" store digest      : %016X", store_digest);
                $display(" register signature: %016X", register_signature);
                $display(" csr signature     : %016X", csr_signature);
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
        if (!rst) begin
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
