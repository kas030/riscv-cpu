`timescale 1ns / 1ps

// fpu_mmio 独立数值测试：直接驱动 MMIO 协议并比较 binary32 位模式。
// 期望值由 IEEE-754 round-to-nearest, ties-to-even 离线计算，不依赖 DUT 实现。
module tb_fpu_mmio;
    localparam logic [31:0] FPU_A_ADDR      = 32'h8020_0070;
    localparam logic [31:0] FPU_B_ADDR      = 32'h8020_0074;
    localparam logic [31:0] FPU_CMD_ADDR    = 32'h8020_0078;
    localparam logic [31:0] FPU_STATUS_ADDR = 32'h8020_007c;
    localparam logic [31:0] FPU_RESULT_ADDR = 32'h8020_0080;

    localparam logic [31:0] CMD_U32_TO_F32 = 32'd1;
    localparam logic [31:0] CMD_DIV_F32    = 32'd2;
    localparam int MAX_WAIT_CYCLES = 48;

    logic        clk = 1'b0;
    logic        rst = 1'b1;
    logic [31:0] addr = 32'd0;
    logic [31:0] wdata = 32'd0;
    logic        wen = 1'b0;
    logic [31:0] rdata;

    int unsigned checks = 0;

    always #5 clk = ~clk;

    fpu_mmio dut (
        .clk   (clk),
        .rst   (rst),
        .addr  (addr),
        .wdata (wdata),
        .wen   (wen),
        .rdata (rdata)
    );

    task automatic mmio_write(
        input logic [31:0] write_addr,
        input logic [31:0] write_data
    );
        begin
            @(negedge clk);
            addr = write_addr;
            wdata = write_data;
            wen = 1'b1;
            @(negedge clk);
            wen = 1'b0;
        end
    endtask

    task automatic mmio_read(
        input  logic [31:0] read_addr,
        output logic [31:0] read_data
    );
        begin
            @(negedge clk);
            addr = read_addr;
            wen = 1'b0;
            #1 read_data = rdata;
        end
    endtask

    task automatic wait_result(output logic [31:0] result);
        logic [31:0] status;
        int cycles;
        begin
            for (cycles = 0; cycles < MAX_WAIT_CYCLES; cycles++) begin
                mmio_read(FPU_STATUS_ADDR, status);
                if (status[1] && !status[0]) begin
                    mmio_read(FPU_RESULT_ADDR, result);
                    return;
                end
            end
            $fatal(1, "FPU timeout after %0d cycles", MAX_WAIT_CYCLES);
        end
    endtask

    task automatic expect_equal(
        input string name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        begin
            checks++;
            if (actual !== expected)
                $fatal(1, "%s: expected 0x%08x, got 0x%08x",
                       name, expected, actual);
            $display("[PASS] %-28s 0x%08x", name, actual);
        end
    endtask

    task automatic test_u32_to_f32(
        input string name,
        input logic [31:0] value,
        input logic [31:0] expected
    );
        logic [31:0] result;
        begin
            mmio_write(FPU_A_ADDR, value);
            mmio_write(FPU_CMD_ADDR, CMD_U32_TO_F32);
            wait_result(result);
            expect_equal(name, result, expected);
        end
    endtask

    task automatic test_div_f32(
        input string name,
        input logic [31:0] numerator,
        input logic [31:0] denominator,
        input logic [31:0] expected
    );
        logic [31:0] result;
        begin
            mmio_write(FPU_A_ADDR, numerator);
            mmio_write(FPU_B_ADDR, denominator);
            mmio_write(FPU_CMD_ADDR, CMD_DIV_F32);
            wait_result(result);
            expect_equal(name, result, expected);
        end
    endtask

    initial begin
        logic [31:0] value;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        mmio_read(FPU_STATUS_ADDR, value);
        expect_equal("reset status", value, 32'h0000_0000);
        mmio_read(FPU_RESULT_ADDR, value);
        expect_equal("reset result", value, 32'h0000_0000);

        // u32 -> binary32：基础值、24 位精度边界、ties-to-even 与最大值。
        test_u32_to_f32("u32 zero",          32'h0000_0000, 32'h0000_0000);
        test_u32_to_f32("u32 one",           32'h0000_0001, 32'h3f80_0000);
        test_u32_to_f32("u32 three",         32'h0000_0003, 32'h4040_0000);
        test_u32_to_f32("u32 exact 24-bit",  32'h00ff_ffff, 32'h4b7f_ffff);
        test_u32_to_f32("u32 2^24",          32'h0100_0000, 32'h4b80_0000);
        test_u32_to_f32("u32 tie even down", 32'h0100_0001, 32'h4b80_0000);
        test_u32_to_f32("u32 exact step",    32'h0100_0002, 32'h4b80_0001);
        test_u32_to_f32("u32 tie even up",   32'h0100_0003, 32'h4b80_0002);
        test_u32_to_f32("u32 2^31",          32'h8000_0000, 32'h4f00_0000);
        test_u32_to_f32("u32 max",           32'hffff_ffff, 32'h4f80_0000);

        // 有限正规 binary32 除法：精确值、循环小数、舍入与符号。
        test_div_f32("div 1 / 2",    32'h3f80_0000, 32'h4000_0000, 32'h3f00_0000);
        test_div_f32("div 3 / 2",    32'h4040_0000, 32'h4000_0000, 32'h3fc0_0000);
        test_div_f32("div 1 / 3",    32'h3f80_0000, 32'h4040_0000, 32'h3eaa_aaab);
        test_div_f32("div 2 / 3",    32'h4000_0000, 32'h4040_0000, 32'h3f2a_aaab);
        test_div_f32("div 10 / 3",   32'h4120_0000, 32'h4040_0000, 32'h4055_5555);
        test_div_f32("div 1000 / 3", 32'h447a_0000, 32'h4040_0000, 32'h43a6_aaab);
        test_div_f32("div -1 / 2",   32'hbf80_0000, 32'h4000_0000, 32'hbf00_0000);
        test_div_f32("div -1 / -2",  32'hbf80_0000, 32'hc000_0000, 32'h3f00_0000);
        test_div_f32("div overflow +", 32'h7f7f_ffff, 32'h3f00_0000, 32'h7f80_0000);
        test_div_f32("div overflow -", 32'hff7f_ffff, 32'h3f00_0000, 32'hff80_0000);
        test_div_f32("div underflow +", 32'h0080_0000, 32'h4000_0000, 32'h0000_0000);
        test_div_f32("div underflow -", 32'h8080_0000, 32'h4000_0000, 32'h8000_0000);

        // CoreMark 报告路径：11628 ticks / 1000，再计算 5000 / seconds。
        test_div_f32("ticks 11628 / 1000",
                     32'h4635_b000, 32'h447a_0000, 32'h413a_0c4a);
        test_div_f32("iterations / seconds",
                     32'h459c_4000, 32'h413a_0c4a, 32'h43d6_ff8f);

        // 模块对零和不支持的非正规/无限输入定义的最小化行为。
        test_div_f32("div +0 / 2",       32'h0000_0000, 32'h4000_0000, 32'h0000_0000);
        test_div_f32("div -0 / 2",       32'h8000_0000, 32'h4000_0000, 32'h8000_0000);
        test_div_f32("div 2 / +0",       32'h4000_0000, 32'h0000_0000, 32'h7f80_0000);
        test_div_f32("div -2 / +0",      32'hc000_0000, 32'h0000_0000, 32'hff80_0000);
        test_div_f32("div normal / inf", 32'h3f80_0000, 32'h7f80_0000, 32'h7fc0_0000);
        test_div_f32("div subnormal",     32'h0000_0001, 32'h3f80_0000, 32'h7fc0_0000);

        $display("[PASS] fpu_mmio numeric test: %0d checks", checks);
        $finish;
    end
endmodule
