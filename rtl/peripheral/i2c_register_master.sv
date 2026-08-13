`timescale 1ns / 1ps

/*
 * 单字节寄存器型 I2C 主机。
 *
 * read_not_write=0:
 *   START -> address(W) -> register -> write_data -> STOP
 * read_not_write=1:
 *   START -> address(W) -> register -> repeated START -> address(R)
 *         -> read_data -> NACK -> STOP
 *
 * SCL/SDA 只会主动拉低，释放后的高电平由板外上拉电阻提供。BME280 不使用
 * clock stretching，因此本模块不等待 SCL 回读。done 和 ack_error 保持到下一次
 * start，便于没有 ready/valid 的 CPU MMIO 总线轮询。
 */
module i2c_register_master #(
    parameter integer CLK_FREQ_HZ = 200_000_000,
    parameter integer I2C_FREQ_HZ = 100_000
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       start,
    input  logic       read_not_write,
    input  logic [6:0] device_addr,
    input  logic [7:0] register_addr,
    input  logic [7:0] write_data,
    output logic [7:0] read_data,
    output logic       busy,
    output logic       done,
    output logic       ack_error,
    inout  wire        i2c_scl,
    inout  wire        i2c_sda
);
    localparam integer HALF_PERIOD_CYCLES = CLK_FREQ_HZ / (I2C_FREQ_HZ * 2);
    localparam integer DIV_WIDTH = (HALF_PERIOD_CYCLES <= 1) ?
                                   1 : $clog2(HALF_PERIOD_CYCLES);

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_START_HOLD,
        ST_START_LOW,
        ST_TX_LOW,
        ST_TX_HIGH,
        ST_ACK_LOW,
        ST_ACK_HIGH,
        ST_RESTART_LOW,
        ST_RESTART_HIGH,
        ST_RESTART_START,
        ST_RX_LOW,
        ST_RX_HIGH,
        ST_NACK_LOW,
        ST_NACK_HIGH,
        ST_STOP_LOW,
        ST_STOP_HIGH
    } state_t;

    typedef enum logic [1:0] {
        TX_ADDR_WRITE,
        TX_REGISTER,
        TX_WRITE_DATA,
        TX_ADDR_READ
    } tx_stage_t;

    state_t state;
    tx_stage_t tx_stage;
    logic [DIV_WIDTH-1:0] divider;
    logic [7:0] tx_byte;
    logic [7:0] rx_shift;
    logic [2:0] bit_index;
    logic [6:0] device_addr_q;
    logic [7:0] register_addr_q;
    logic [7:0] write_data_q;
    logic       read_not_write_q;
    logic       scl_drive_low;
    logic       sda_drive_low;

    assign i2c_scl = scl_drive_low ? 1'b0 : 1'bz;
    assign i2c_sda = sda_drive_low ? 1'b0 : 1'bz;

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= ST_IDLE;
            tx_stage           <= TX_ADDR_WRITE;
            divider            <= '0;
            tx_byte            <= 8'd0;
            rx_shift           <= 8'd0;
            bit_index          <= 3'd7;
            device_addr_q      <= 7'h76;
            register_addr_q    <= 8'd0;
            write_data_q       <= 8'd0;
            read_not_write_q   <= 1'b0;
            read_data          <= 8'd0;
            busy               <= 1'b0;
            done               <= 1'b0;
            ack_error          <= 1'b0;
            scl_drive_low      <= 1'b0;
            sda_drive_low      <= 1'b0;
        end else if (state == ST_IDLE) begin
            divider       <= '0;
            scl_drive_low <= 1'b0;
            sda_drive_low <= 1'b0;
            if (start) begin
                device_addr_q    <= device_addr;
                register_addr_q  <= register_addr;
                write_data_q     <= write_data;
                read_not_write_q <= read_not_write;
                busy             <= 1'b1;
                done             <= 1'b0;
                ack_error        <= 1'b0;
                state            <= ST_START_HOLD;
            end
        end else if (divider == HALF_PERIOD_CYCLES - 1) begin
            divider <= '0;
            case (state)
                ST_START_HOLD: begin
                    // SDA 下降且 SCL 为高，产生 START。
                    sda_drive_low <= 1'b1;
                    state         <= ST_START_LOW;
                end

                ST_START_LOW: begin
                    scl_drive_low <= 1'b1;
                    tx_byte       <= {device_addr_q, 1'b0};
                    tx_stage      <= TX_ADDR_WRITE;
                    bit_index     <= 3'd7;
                    sda_drive_low <= ~device_addr_q[6];
                    state         <= ST_TX_LOW;
                end

                ST_TX_LOW: begin
                    // 数据已在 SCL 低电平期间稳定，释放 SCL 进入高电平。
                    scl_drive_low <= 1'b0;
                    state         <= ST_TX_HIGH;
                end

                ST_TX_HIGH: begin
                    scl_drive_low <= 1'b1;
                    if (bit_index == 3'd0) begin
                        // 第 9 个时钟由从机驱动 ACK/NACK。
                        sda_drive_low <= 1'b0;
                        state         <= ST_ACK_LOW;
                    end else begin
                        bit_index     <= bit_index - 1'b1;
                        sda_drive_low <= ~tx_byte[bit_index - 1'b1];
                        state         <= ST_TX_LOW;
                    end
                end

                ST_ACK_LOW: begin
                    scl_drive_low <= 1'b0;
                    state         <= ST_ACK_HIGH;
                end

                ST_ACK_HIGH: begin
                    // 在 SCL 高电平末端采样 ACK，然后立即进入下一字节或 STOP。
                    scl_drive_low <= 1'b1;
                    case (i2c_sda)
                        1'b0: begin
                            case (tx_stage)
                                TX_ADDR_WRITE: begin
                                    tx_byte       <= register_addr_q;
                                    tx_stage      <= TX_REGISTER;
                                    bit_index     <= 3'd7;
                                    sda_drive_low <= ~register_addr_q[7];
                                    state         <= ST_TX_LOW;
                                end

                                TX_REGISTER: begin
                                    if (read_not_write_q) begin
                                        sda_drive_low <= 1'b0;
                                        state         <= ST_RESTART_LOW;
                                    end else begin
                                        tx_byte       <= write_data_q;
                                        tx_stage      <= TX_WRITE_DATA;
                                        bit_index     <= 3'd7;
                                        sda_drive_low <= ~write_data_q[7];
                                        state         <= ST_TX_LOW;
                                    end
                                end

                                TX_WRITE_DATA: begin
                                    sda_drive_low <= 1'b1;
                                    state         <= ST_STOP_LOW;
                                end

                                default: begin // TX_ADDR_READ
                                    bit_index     <= 3'd7;
                                    rx_shift      <= 8'd0;
                                    sda_drive_low <= 1'b0;
                                    state         <= ST_RX_LOW;
                                end
                            endcase
                        end

                        default: begin
                            ack_error     <= 1'b1;
                            sda_drive_low <= 1'b1;
                            state         <= ST_STOP_LOW;
                        end
                    endcase
                end

                ST_RESTART_LOW: begin
                    // 先把总线恢复为高电平，再在 SCL 高时拉低 SDA。
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                    state         <= ST_RESTART_HIGH;
                end

                ST_RESTART_HIGH: begin
                    sda_drive_low <= 1'b1;
                    state         <= ST_RESTART_START;
                end

                ST_RESTART_START: begin
                    scl_drive_low <= 1'b1;
                    tx_byte       <= {device_addr_q, 1'b1};
                    tx_stage      <= TX_ADDR_READ;
                    bit_index     <= 3'd7;
                    sda_drive_low <= ~device_addr_q[6];
                    state         <= ST_TX_LOW;
                end

                ST_RX_LOW: begin
                    scl_drive_low <= 1'b0;
                    state         <= ST_RX_HIGH;
                end

                ST_RX_HIGH: begin
                    scl_drive_low <= 1'b1;
                    case (i2c_sda)
                        1'b0: rx_shift[bit_index] <= 1'b0;
                        default: rx_shift[bit_index] <= 1'b1;
                    endcase

                    if (bit_index == 3'd0) begin
                        case (i2c_sda)
                            1'b0: read_data <= {rx_shift[7:1], 1'b0};
                            default: read_data <= {rx_shift[7:1], 1'b1};
                        endcase
                        // 单字节读取后主机发送 NACK。
                        sda_drive_low <= 1'b0;
                        state         <= ST_NACK_LOW;
                    end else begin
                        bit_index <= bit_index - 1'b1;
                        state     <= ST_RX_LOW;
                    end
                end

                ST_NACK_LOW: begin
                    scl_drive_low <= 1'b0;
                    state         <= ST_NACK_HIGH;
                end

                ST_NACK_HIGH: begin
                    scl_drive_low <= 1'b1;
                    sda_drive_low <= 1'b1;
                    state         <= ST_STOP_LOW;
                end

                ST_STOP_LOW: begin
                    // SDA 保持低，先释放 SCL。
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b1;
                    state         <= ST_STOP_HIGH;
                end

                ST_STOP_HIGH: begin
                    // SCL 为高时释放 SDA，产生 STOP。
                    sda_drive_low <= 1'b0;
                    busy          <= 1'b0;
                    done          <= 1'b1;
                    state         <= ST_IDLE;
                end

                default: begin
                    state         <= ST_IDLE;
                    busy          <= 1'b0;
                    ack_error     <= 1'b1;
                    scl_drive_low <= 1'b0;
                    sda_drive_low <= 1'b0;
                end
            endcase
        end else begin
            divider <= divider + 1'b1;
        end
    end

endmodule
