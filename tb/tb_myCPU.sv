`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_myCPU.sv —— RV32I CPU 性能测试 testbench（带性能计数 + 自动停机）
//
// 在原版基础上新增：
//   - virtual_led / virtual_seg 引出 wire，便于波形与脚本访问
//   - cnt_cycles      : cpu_clk 周期数
//   - cnt_writeback   : reg_file 写回数（≈ 写寄存器的指令数，含 alu/load/jal）
//   - cnt_store       : 存储指令数 (SW/SH/SB)
//   - cnt_branch      : 已 taken 的分支/跳转数
//   - 分支预测统计：条件分支解析数、预测 taken 数、预测错误数、冲刷次数
//   - 程序写 0xC0DEC0DE 或 0xDEADBEEF 到 LED 后自动 $finish 并打印性能指标
//   - 200µs 兜底超时
//////////////////////////////////////////////////////////////////////////////////
module tb_myCPU;
    reg  clk;
    wire [31:0] led;
    wire [39:0] seg;

    top uut (
        .i_sys_clk_p (clk),
        .i_sys_clk_n (~clk),
        .i_uart_rx   (1'b1),
        .o_uart_tx   (),
        .virtual_led (led),
        .virtual_seg (seg)
    );

    // 200MHz 差分输入时钟（pll 内部分频出 cpu_clk）
    initial clk = 1'b0;
    always  #2.5 clk = ~clk;

    // ===================================================================
    //  性能计数（在 cpu_clk 域采样）
    // ===================================================================
    wire cpu_clk = uut.student_top_inst.w_cpu_clk;

    // CPU 时钟频率 (MHz)，按你 PLL 实际配置改
    localparam real CPU_CLK_MHZ = 200.0;

    integer cnt_cycles    = 0;
    integer cnt_writeback = 0;
    integer cnt_store     = 0;
    integer cnt_branch    = 0;
    integer cnt_cond_branch      = 0;
    integer cnt_pred_taken       = 0;
    integer cnt_pred_correct     = 0;
    integer cnt_cond_mispredict  = 0;
    integer cnt_mispredict       = 0;
    integer cnt_flush_if_id      = 0;
    integer cnt_flush_id_ex      = 0;
    integer approx_inst;

    always @(posedge cpu_clk) begin
        cnt_cycles <= cnt_cycles + 1;

        // 写 reg_file 的指令（alu / load / lui / auipc / jal-with-rd / csrrw 等）
        if (uut.student_top_inst.Core_cpu.rf_inst.wen &&
            uut.student_top_inst.Core_cpu.rf_inst.waddr != 5'd0)
            cnt_writeback <= cnt_writeback + 1;

        // 存储指令（写 BRAM 或 MMIO）
        if (uut.student_top_inst.Core_cpu.perip_wen)
            cnt_store <= cnt_store + 1;

        // 已 taken 分支或跳转（J / JAL / JALR / 满足条件的 B 类）
        if (uut.student_top_inst.Core_cpu.BranchTaken)
            cnt_branch <= cnt_branch + 1;

        // 动态预测统计：只统计 EX 级已经解析的条件分支（EX_NpcOp == 2'b01）。
        if (!uut.student_top_inst.Core_cpu.EX_busy &&
            uut.student_top_inst.Core_cpu.EX_NpcOp == 2'b01) begin
            cnt_cond_branch <= cnt_cond_branch + 1;
            if (uut.student_top_inst.Core_cpu.EX_pred_taken)
                cnt_pred_taken <= cnt_pred_taken + 1;
            if (!uut.student_top_inst.Core_cpu.BranchMispredict)
                cnt_pred_correct <= cnt_pred_correct + 1;
            if (uut.student_top_inst.Core_cpu.BranchMispredict)
                cnt_cond_mispredict <= cnt_cond_mispredict + 1;
        end

        if (uut.student_top_inst.Core_cpu.BranchMispredict)
            cnt_mispredict <= cnt_mispredict + 1;
        if (uut.student_top_inst.Core_cpu.Flush_IF_ID)
            cnt_flush_if_id <= cnt_flush_if_id + 1;
        if (uut.student_top_inst.Core_cpu.Flush_ID_EX)
            cnt_flush_id_ex <= cnt_flush_id_ex + 1;
    end

    // ===================================================================
    //  PASS / FAIL 检测（监听 LED 寄存器）
    // ===================================================================
    initial begin
        $display("==================================================");
        $display(" RV32I CPU Performance Test ");
        $display("==================================================");

        // 等待程序写 PASS / FAIL magic 到 LED
        wait (led == 32'hC0DEC0DE || led == 32'hDEADBEEF);
        #200;       // 让流水线最后几条指令排空

        approx_inst = cnt_writeback + cnt_store + cnt_branch;

        $display("--------------------------------------------------");
        if (led == 32'hC0DEC0DE)
            $display(">>> [PASS] virtual_led = 0x%08X", led);
        else
            $display(">>> [FAIL] virtual_led = 0x%08X", led);
        $display("--------------------------------------------------");
        $display(" cycles            : %0d", cnt_cycles);
        $display(" writeback (reg_file)    : %0d", cnt_writeback);
        $display(" stores            : %0d", cnt_store);
        $display(" taken branches    : %0d", cnt_branch);
        $display(" cond branches     : %0d", cnt_cond_branch);
        $display(" pred taken        : %0d", cnt_pred_taken);
        $display(" pred correct      : %0d", cnt_pred_correct);
        $display(" cond mispredicts  : %0d", cnt_cond_mispredict);
        $display(" mispredicts       : %0d", cnt_mispredict);
        $display(" flush IF/ID       : %0d", cnt_flush_if_id);
        $display(" flush ID/EX       : %0d", cnt_flush_id_ex);
        $display(" approx total inst : %0d", approx_inst);
        if (approx_inst > 0)
            $display(" CPI (approx)      : %0.3f", cnt_cycles*1.0 / approx_inst);
        $display(" cpu_clk           : %0.1f MHz", CPU_CLK_MHZ);
        $display(" runtime           : %0.3f us", cnt_cycles / CPU_CLK_MHZ);
        if (approx_inst > 0)
            $display(" MIPS (approx)     : %0.1f", CPU_CLK_MHZ * approx_inst / cnt_cycles);
        $display("==================================================");
        $finish;
    end

    // 兜底超时 200µs
    initial begin
        #500_000_000;
        $display(">>> [TIMEOUT] led=0x%08X cycles=%0d", led, cnt_cycles);
        $finish;
    end
endmodule
