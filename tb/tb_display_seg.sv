`timescale 1ns / 1ps

module tb_display_seg;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [31:0] s = 32'h1234_abcd;
    logic [31:0] raw_lo = 32'h5b_e6_4f_39;
    logic [31:0] raw_hi = 32'h78_79_54_00;
    logic raw_mode = 1'b0;
    logic [6:0] seg1, seg2, seg3, seg4;
    logic dp1, dp2, dp3, dp4;
    logic [7:0] ans;

    always #2.5 clk = ~clk;

    display_seg dut (
        .clk(clk),
        .rst(rst),
        .s(s),
        .raw_lo(raw_lo),
        .raw_hi(raw_hi),
        .raw_mode(raw_mode),
        .seg1(seg1),
        .seg2(seg2),
        .seg3(seg3),
        .seg4(seg4),
        .dp1(dp1),
        .dp2(dp2),
        .dp3(dp3),
        .dp4(dp4),
        .ans(ans)
    );

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;

        wait (dut.count[4] == 1'b0);
        #1;
        if (ans !== 8'haa || seg1 !== 7'h39 || seg2 !== 7'h77 ||
            seg3 !== 7'h4f || seg4 !== 7'h06 || {dp4, dp3, dp2, dp1} !== 4'b0000)
            $fatal(1, "legacy even-digit phase mismatch");

        wait (dut.count[4] == 1'b1);
        #1;
        if (ans !== 8'h55 || seg1 !== 7'h5e || seg2 !== 7'h7c ||
            seg3 !== 7'h66 || seg4 !== 7'h5b || {dp4, dp3, dp2, dp1} !== 4'b0000)
            $fatal(1, "legacy odd-digit phase mismatch");

        raw_mode = 1'b1;
        wait (dut.count[4] == 1'b0);
        #1;
        if (ans !== 8'haa || seg1 !== 7'h4f || seg2 !== 7'h5b ||
            seg3 !== 7'h54 || seg4 !== 7'h78 || {dp4, dp3, dp2, dp1} !== 4'b0000)
            $fatal(1, "raw even-digit phase mismatch");

        wait (dut.count[4] == 1'b1);
        #1;
        if (ans !== 8'h55 || seg1 !== 7'h39 || seg2 !== 7'h66 ||
            seg3 !== 7'h00 || seg4 !== 7'h79 || {dp4, dp3, dp2, dp1} !== 4'b0010)
            $fatal(1, "raw odd-digit phase or decimal point mismatch");

        $display("PASS: legacy and raw eight-digit display modes");
        $finish;
    end
endmodule
