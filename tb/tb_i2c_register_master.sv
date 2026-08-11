`timescale 1ns / 1ps

module tb_i2c_register_master;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start = 1'b0;
    logic read_not_write = 1'b0;
    logic [6:0] device_addr = 7'h76;
    logic [7:0] register_addr = 8'd0;
    logic [7:0] write_data = 8'd0;
    logic [7:0] read_data;
    logic busy;
    logic done;
    logic ack_error;
    logic slave_sda_low = 1'b0;
    integer failures = 0;

    tri1 i2c_scl;
    tri1 i2c_sda;
    assign i2c_sda = slave_sda_low ? 1'b0 : 1'bz;

    always #500 clk = ~clk;

    i2c_register_master #(
        .CLK_FREQ_HZ (1_000_000),
        .I2C_FREQ_HZ (100_000)
    ) dut (
        .clk,
        .rst,
        .start,
        .read_not_write,
        .device_addr,
        .register_addr,
        .write_data,
        .read_data,
        .busy,
        .done,
        .ack_error,
        .i2c_scl,
        .i2c_sda
    );

    task automatic wait_start_condition;
        begin
            @(negedge i2c_sda);
            if (i2c_scl !== 1'b1) begin
                $display("FAIL: SDA did not fall while SCL was high");
                failures++;
            end
        end
    endtask

    task automatic receive_byte(output logic [7:0] value);
        integer i;
        begin
            for (i = 7; i >= 0; i--) begin
                @(posedge i2c_scl);
                value[i] = i2c_sda;
            end
        end
    endtask

    task automatic send_ack;
        begin
            @(negedge i2c_scl);
            slave_sda_low = 1'b1;
            @(posedge i2c_scl);
            @(negedge i2c_scl);
            slave_sda_low = 1'b0;
        end
    endtask

    task automatic wait_stop_condition;
        begin
            @(posedge i2c_scl);
            @(posedge i2c_sda);
            if (i2c_scl !== 1'b1) begin
                $display("FAIL: SDA did not rise while SCL was high");
                failures++;
            end
        end
    endtask

    task automatic emulate_write(input logic [7:0] expected_reg,
                                 input logic [7:0] expected_data);
        logic [7:0] value;
        begin
            wait_start_condition();
            receive_byte(value);
            if (value !== 8'hec) begin
                $display("FAIL: write address byte=%02x", value);
                failures++;
            end
            send_ack();
            receive_byte(value);
            if (value !== expected_reg) begin
                $display("FAIL: register byte=%02x expected=%02x", value, expected_reg);
                failures++;
            end
            send_ack();
            receive_byte(value);
            if (value !== expected_data) begin
                $display("FAIL: write byte=%02x expected=%02x", value, expected_data);
                failures++;
            end
            send_ack();
            wait_stop_condition();
        end
    endtask

    task automatic emulate_read(input logic [7:0] expected_reg,
                                input logic [7:0] returned_data);
        logic [7:0] value;
        integer i;
        begin
            wait_start_condition();
            receive_byte(value);
            if (value !== 8'hec) begin
                $display("FAIL: initial read address byte=%02x", value);
                failures++;
            end
            send_ack();
            receive_byte(value);
            if (value !== expected_reg) begin
                $display("FAIL: read register byte=%02x expected=%02x", value, expected_reg);
                failures++;
            end
            send_ack();

            wait_start_condition();
            receive_byte(value);
            if (value !== 8'hed) begin
                $display("FAIL: repeated-start address byte=%02x", value);
                failures++;
            end
            send_ack();

            for (i = 7; i >= 0; i--) begin
                slave_sda_low = ~returned_data[i];
                @(posedge i2c_scl);
                @(negedge i2c_scl);
            end
            slave_sda_low = 1'b0;
            @(posedge i2c_scl);
            if (i2c_sda !== 1'b1) begin
                $display("FAIL: master did not NACK the single read byte");
                failures++;
            end
            @(negedge i2c_scl);
            wait_stop_condition();
        end
    endtask

    task automatic pulse_start(input logic is_read);
        begin
            @(negedge clk);
            read_not_write = is_read;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_done;
        integer timeout;
        begin
            timeout = 0;
            while (!done && timeout < 2000) begin
                @(posedge clk);
                timeout++;
            end
            if (!done) begin
                $display("FAIL: transaction timeout");
                failures++;
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1'b0;

        register_addr = 8'hf4;
        write_data = 8'h25;
        fork
            emulate_write(8'hf4, 8'h25);
            pulse_start(1'b0);
        join
        wait_done();
        if (ack_error || busy)
            failures++;

        register_addr = 8'hd0;
        fork
            emulate_read(8'hd0, 8'h60);
            pulse_start(1'b1);
        join
        wait_done();
        if (ack_error || busy || read_data !== 8'h60) begin
            $display("FAIL: read result=%02x busy=%b nack=%b", read_data, busy, ack_error);
            failures++;
        end

        // 不启动从机模型，确认地址 NACK 会结束事务并置错误位。
        register_addr = 8'h00;
        pulse_start(1'b0);
        wait_done();
        if (!ack_error || busy) begin
            $display("FAIL: NACK result busy=%b nack=%b", busy, ack_error);
            failures++;
        end

        if (failures == 0)
            $display("PASS: i2c_register_master write/read/NACK");
        else
            $fatal(1, "FAIL: i2c_register_master failures=%0d", failures);
        $finish;
    end

endmodule
