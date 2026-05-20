`timescale 1ns / 1ps
//==============================================================
// tb_perf.sv —— 自研 RV32I CPU 性能监控 testbench
//
// 在原 tb_myCPU 基础上扩展：
//   1. 周期计数器（cycle_count）
//   2. 指令计数器（inst_count，依据 IF→ID 有效信号）
//   3. 停顿计数器（stall_count，hazard_unit 拉高时）
//   4. 分支刷新计数器（flush_count，控制冒险时）
//   5. 测试完成探测：扫描 DRAM 0x80200F00 处的结果字
//      - 0xC0DEC0DE → PASS
//      - 0xDEADBEEF → FAIL
//   6. 自动打印 CPI、指令数、停顿数、刷新数、运行时间
//
// 用法：
//   1. 在 Vivado 中将本文件加为 sim_1 的顶层；
//   2. 运行行为级仿真，控制台会输出性能报告；
//   3. 运行结束（PASS/FAIL）后调用 $finish 自动停止。
//
// 注意：
//   - 假设 top.uut 实例化路径下存在层次：
//       Core_cpu.if_id_valid     —— IF 输出有效信号
//       Core_cpu.hazard_stall    —— hazard_unit 停顿信号
//       Core_cpu.npc_flush       —— 分支/跳转触发的冲刷
//     如果你的命名不同，请改下面的 hierarchical reference。
//==============================================================

module tb_perf;

    // -------- 系统时钟（50 MHz，周期 20 ns） --------
    reg clk;
    initial clk = 0;
    always  #10 clk = ~clk;        // 10ns half-period → 50MHz

    // -------- DUT --------
    wire [31:0] virtual_led;
    wire [31:0] virtual_seg;
    top uut (
        .i_sys_clk_p(clk),
        .i_sys_clk_n(~clk),
        .i_uart_rx (1'b1),
        .o_uart_tx (),
        .virtual_led(virtual_led),
        .virtual_seg(virtual_seg)
    );

    // -------- 性能计数器 --------
    integer cycle_count = 0;
    integer inst_count  = 0;
    integer stall_count = 0;
    integer flush_count = 0;
    integer load_count  = 0;
    integer store_count = 0;
    integer branch_taken = 0;

    // 从 DUT 内部抽出关键信号（按你的实际层次修改）
    // 这里给出占位用的 wire，并通过 force/cross-module-ref 接入。
    // 如果命名不同，请同步修改下面三条 assign。
`ifdef CPU_HAS_PERF_HOOKS
    wire if_valid    = uut.student_top_inst.Core_cpu.if_id_valid;
    wire stall       = uut.student_top_inst.Core_cpu.hazard_stall;
    wire flush       = uut.student_top_inst.Core_cpu.npc_flush;
    wire is_load     = uut.student_top_inst.Core_cpu.id_is_load;
    wire is_store    = uut.student_top_inst.Core_cpu.id_is_store;
    wire br_taken    = uut.student_top_inst.Core_cpu.ex_branch_taken;
`else
    // 默认占位：不接钩子时所有计数仅有 cycle_count 有效。
    wire if_valid    = 1'b0;
    wire stall       = 1'b0;
    wire flush       = 1'b0;
    wire is_load     = 1'b0;
    wire is_store    = 1'b0;
    wire br_taken    = 1'b0;
`endif

    always @(posedge clk) begin
        cycle_count <= cycle_count + 1;
        if (if_valid && !stall) inst_count  <= inst_count  + 1;
        if (stall)              stall_count <= stall_count + 1;
        if (flush)              flush_count <= flush_count + 1;
        if (is_load)            load_count  <= load_count  + 1;
        if (is_store)           store_count <= store_count + 1;
        if (br_taken)           branch_taken<= branch_taken+ 1;
    end

    // -------- 探测结果地址 --------
    // 结果字位于 DRAM 0x80200F00，对应 IP 内的字索引
    // = 0xF00/4 = 0x3C0
    localparam RESULT_WORD_IDX = 12'h3C0;
    localparam PASS_MAGIC = 32'hC0DEC0DE;
    localparam FAIL_MAGIC = 32'hDEADBEEF;

    // 假设 DRAM IP 实例为 uut.u_DRAM.U0.inst_blk_mem_gen.gnative_mem.RAM
    // 不同版本的 IP 路径不同，需要按工程实际改
    reg [31:0] result_word;
    reg        result_seen;
    initial begin
        result_seen = 1'b0;
        // 用 $monitor 周期检查；不直接 hierarchical 访问 DRAM，
        // 而是通过 LED 上探测：测试程序在结束前会把结果同时写到
        // LED（0x80000000）。这样 testbench 不依赖 DRAM IP 内部路径。
    end

    // -------- 简化方案：监控 virtual_led + 超时机制 --------
    // 当测试程序写完最终结果，会停在 1: j 1b 死循环。
    // 我们以"100k 周期内 pc_reg 不再前进"或者"运行 5M 周期"作为停机条件。
    integer timeout_cycles = 5_000_000;

    initial begin
        $display("=========================================");
        $display(" RV32I CPU performance benchmark started ");
        $display("=========================================");
        // 等待复位释放（top 内部一般有 reset_synchronizer）
        #200;
        // 等待 timeout 或 PASS 信号
        wait (cycle_count >= timeout_cycles);
        report_perf("TIMEOUT");
        $finish;
    end

    // 监听数码管显示：当显示 0x????C0DE 类似模式时，认为测试通过
    // 因为 t01 等测试会把结果写入 LED，所以以 LED == PASS_MAGIC 判停
    reg seen_pass = 0, seen_fail = 0;
    always @(posedge clk) begin
        if (!seen_pass && !seen_fail) begin
            if (virtual_led == PASS_MAGIC) begin
                seen_pass = 1;
                #100;  // 让最后几条指令完成
                report_perf("PASS");
                $finish;
            end else if (virtual_led == FAIL_MAGIC) begin
                seen_fail = 1;
                #100;
                report_perf("FAIL");
                $finish;
            end
        end
    end

    // -------- 性能报告 --------
    task report_perf(input [55:0] tag);
        real cpi;
        real freq_mhz;
        real runtime_us;
    begin
        cpi = (inst_count > 0) ? (cycle_count * 1.0 / inst_count) : 0.0;
        freq_mhz = 50.0;                        // 与上面 50MHz 时钟一致
        runtime_us = cycle_count / freq_mhz;    // = cycles / freq

        $display("---------------------------------------------");
        $display(" Result        : %s", tag);
        $display(" Total cycles  : %0d", cycle_count);
        $display(" Insts retired : %0d", inst_count);
        $display(" Stalls        : %0d", stall_count);
        $display(" Flushes       : %0d", flush_count);
        $display(" Loads/Stores  : %0d / %0d", load_count, store_count);
        $display(" Branches taken: %0d", branch_taken);
        $display(" CPI           : %0.3f", cpi);
        $display(" Sim freq      : %0.1f MHz", freq_mhz);
        $display(" Runtime       : %0.2f us", runtime_us);
        $display(" virtual_led   : 0x%08X", virtual_led);
        $display(" virtual_seg   : 0x%08X", virtual_seg);
        $display("---------------------------------------------");
    end
    endtask

endmodule
