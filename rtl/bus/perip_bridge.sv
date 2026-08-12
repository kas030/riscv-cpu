`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/04/22 10:25:24
// Design Name: 
// Module Name: perip_bridge
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module perip_bridge(
    input  logic         clk				,
    input  logic         cnt_clk			,
    input  logic         rst                ,

    input  logic [31:0]  perip_addr			,
    input  logic [31:0]  perip_wdata		,
    input  logic         perip_wen			,
	input  logic [1:0]	 perip_mask			,
    output logic [31:0]  perip_rdata		,

    input  logic [63:0]  virtual_sw_input	,
    input  logic [7:0]   virtual_key_input	,	

	output logic [39:0]  virtual_seg_output	,
    output logic [31:0]  virtual_led_output,

    /* UART 透传（50MHz 域，接 twin_controller 与 uart） */
    output logic [7:0]   uart_tx_data       ,
    output logic         uart_tx_start      ,
    input  logic         uart_tx_busy       ,
    input  logic [7:0]   uart_rx_data       ,
    input  logic         uart_rx_ready      ,
    input  logic         uart_passthrough   ,
    output logic         uart_passthrough_req, // 透传请求脉冲（50MHz，接 twin_controller）

    /* J7 上的 BME280 I2C 总线；只允许开漏拉低，外部 10k 电阻负责上拉 */
    inout  wire          bme_scl,
    inout  wire          bme_sda
);
    localparam BRAM_ADDR_TAG = 14'h2004;  // 0x8010_0000..0x8013_FFFF
    localparam SW0_ADDR  = 32'h8020_0000;  // sw[31:0]
    localparam SW1_ADDR  = 32'h8020_0004;  // sw[63:32]
    localparam KEY_ADDR  = 32'h8020_0010;  // key[7:0]
    localparam SEG_ADDR  = 32'h8020_0020;  // seg
    localparam LED_ADDR  = 32'h8020_0040;  // led[31:0]
    localparam CNT_ADDR  = 32'h8020_0050;  // counter
    localparam CNT_START_CMD = 32'h8000_0000;
    localparam CNT_STOP_CMD  = 32'hFFFF_FFFF;
    localparam UART_DATA_ADDR   = 32'h8020_0060;  // 写=发送，读=接收并清 valid
    localparam UART_STATUS_ADDR = 32'h8020_0064;  // bit0=TX_BUSY，bit1=RX_VALID，bit2=PASSTHROUGH；写=请求透传
    localparam I2C_DEV_ADDR     = 32'h8020_0068;  // 低 7 位：从机地址，复位值 0x76
    localparam I2C_REG_ADDR     = 32'h8020_006C;  // 低 8 位：从机寄存器地址
    localparam I2C_DATA_ADDR    = 32'h8020_0070;  // 写数据/最近一次读数据
    localparam I2C_CTRL_ADDR    = 32'h8020_0074;  // 写 bit0=START bit1=READ；读 bit0=BUSY bit1=DONE bit2=NACK
    localparam SEG_RAW_LO_ADDR  = 32'h8020_0078;  // 右侧 4 位，每字节 bit7=小数点、bit6:0=段码
    localparam SEG_RAW_HI_ADDR  = 32'h8020_007C;  // 左侧 4 位；写入后切换到原始段码模式

    logic [31:0] LED;
    logic [31:0] seg_wdata, seg_raw_lo, seg_raw_hi;
    logic [31:0] cnt_rdata, mmio_rdata, bram_rdata;
    logic [31:0] uart_rdata;
    logic [39:0] seg_output;
    logic [3:0] seg_dp;
    logic seg_raw_mode;
    logic cnt_enable_cfg;
    logic bram_hit, bram_ren, bram_wen, bram_resp_valid;
    logic [6:0] i2c_device_addr;
    logic [7:0] i2c_register_addr, i2c_write_data, i2c_read_data;
    logic i2c_start, i2c_busy, i2c_done, i2c_ack_error;

    assign bram_hit = (perip_addr[31:18] == BRAM_ADDR_TAG);
    assign bram_ren = ~perip_wen & bram_hit;
    assign bram_wen = perip_wen & bram_hit;

    // we don't care perip_mask in LED, SEG, SW & KEY, only care in BRAM
    // write process
    always_ff @(posedge clk) begin
        if (rst) begin
            LED            <= 32'd0;
            seg_wdata      <= 32'd0;
            seg_raw_lo     <= 32'd0;
            seg_raw_hi     <= 32'd0;
            seg_raw_mode   <= 1'b0;
            cnt_enable_cfg <= 1'b0;
            i2c_device_addr   <= 7'h76;
            i2c_register_addr <= 8'd0;
            i2c_write_data    <= 8'd0;
        end else if (perip_wen) begin
            case (perip_addr)
                LED_ADDR:   LED <= perip_wdata;
                SEG_ADDR: begin
                    seg_wdata    <= perip_wdata;
                    seg_raw_mode <= 1'b0;
                end
                SEG_RAW_LO_ADDR: seg_raw_lo <= perip_wdata;
                SEG_RAW_HI_ADDR: begin
                    seg_raw_hi   <= perip_wdata;
                    seg_raw_mode <= 1'b1;
                end
                I2C_DEV_ADDR:  i2c_device_addr   <= perip_wdata[6:0];
                I2C_REG_ADDR:  i2c_register_addr <= perip_wdata[7:0];
                I2C_DATA_ADDR: i2c_write_data    <= perip_wdata[7:0];
                CNT_ADDR: begin
                    if (perip_wdata == CNT_START_CMD) begin
                        cnt_enable_cfg <= 1'b1;
                    end else if (perip_wdata == CNT_STOP_CMD) begin
                        cnt_enable_cfg <= 1'b0;
                    end
                end
                default: ;
            endcase
        end
    end

    // read process: in one cycle
    always_comb begin
        if (~perip_wen) begin
            case (perip_addr)
                SW0_ADDR:  mmio_rdata = virtual_sw_input[31:0];
                SW1_ADDR:  mmio_rdata = virtual_sw_input[63:32];
                KEY_ADDR:  mmio_rdata = {24'd0, virtual_key_input};
                SEG_ADDR:  mmio_rdata = seg_wdata;
                UART_DATA_ADDR:   mmio_rdata = uart_rdata;  // uart_addr=00
                UART_STATUS_ADDR: mmio_rdata = uart_rdata;  // uart_addr=01
                I2C_DEV_ADDR:     mmio_rdata = {25'd0, i2c_device_addr};
                I2C_REG_ADDR:     mmio_rdata = {24'd0, i2c_register_addr};
                I2C_DATA_ADDR:    mmio_rdata = {24'd0, i2c_read_data};
                I2C_CTRL_ADDR:    mmio_rdata = {29'd0, i2c_ack_error, i2c_done, i2c_busy};
                SEG_RAW_LO_ADDR:  mmio_rdata = seg_raw_lo;
                SEG_RAW_HI_ADDR:  mmio_rdata = seg_raw_hi;
                default:   mmio_rdata = 32'hDEAD_BEEF;
            endcase
        end else begin
            mmio_rdata = 32'h0;
        end
    end

    // seg driver
    display_seg seg_driver (
        .clk    (clk),
        .rst    (rst),
        .s      (seg_wdata),
        .raw_lo (seg_raw_lo),
        .raw_hi (seg_raw_hi),
        .raw_mode(seg_raw_mode),
        .seg1   (seg_output[6:0]),
        .seg2   (seg_output[16:10]),
        .seg3   (seg_output[26:20]),
        .seg4   (seg_output[36:30]),
        .dp1    (seg_dp[0]),
        .dp2    (seg_dp[1]),
        .dp3    (seg_dp[2]),
        .dp4    (seg_dp[3]),
        .ans    ({seg_output[39:38], seg_output[29:28], seg_output[19:18], seg_output[9:8]})
    ); 
   
    assign seg_output[7]  = seg_dp[0];
    assign seg_output[17] = seg_dp[1];
    assign seg_output[27] = seg_dp[2];
    assign seg_output[37] = seg_dp[3];
    

    // bram rw
    bram_driver bram_driver_inst (
        .clk				(clk),
        .perip_addr			(perip_addr[17:0]),
        .perip_wdata		(perip_wdata),
        .perip_mask			(perip_mask),
        .bram_ren           (bram_ren),
        .bram_wen 			(bram_wen),
        .perip_rdata		(bram_rdata)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            bram_resp_valid <= 1'b0;
        end else begin
            bram_resp_valid <= bram_ren;
        end
    end

    // counter rw
    counter counter_inst (
        .cpu_clk            (clk),
        .cnt_clk            (cnt_clk),
        .rst                (rst),
        .cnt_enable_cpu     (cnt_enable_cfg),
        .perip_rdata		(cnt_rdata)
    );

    assign perip_rdata = {32{bram_resp_valid}} & bram_rdata |
                         {32{~bram_resp_valid && perip_addr == SW0_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == SW1_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == KEY_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == SEG_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == CNT_ADDR}} & cnt_rdata |
                         {32{~bram_resp_valid && perip_addr == UART_DATA_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == UART_STATUS_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == I2C_DEV_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == I2C_REG_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == I2C_DATA_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == I2C_CTRL_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == SEG_RAW_LO_ADDR}} & mmio_rdata |
                         {32{~bram_resp_valid && perip_addr == SEG_RAW_HI_ADDR}} & mmio_rdata;
    
    assign virtual_led_output = LED;
    assign virtual_seg_output = seg_output;

    // uart 跨时钟域桥（200MHz 侧接 perip 总线子集，50MHz 侧接 twin/uart）
    uart_bridge uart_bridge_inst (
        .clk             (clk),
        .cnt_clk         (cnt_clk),
        .rst             (rst),
        .uart_addr       (perip_addr[3:2]),
        .uart_wdata      (perip_wdata[7:0]),
        .uart_wen        (perip_wen && perip_addr == UART_DATA_ADDR),
        .uart_ren        (~perip_wen && perip_addr == UART_DATA_ADDR),
        .uart_rdata      (uart_rdata),
        .uart_tx_data    (uart_tx_data),
        .uart_tx_start   (uart_tx_start),
        .uart_tx_busy    (uart_tx_busy),
        .uart_rx_data    (uart_rx_data),
        .uart_rx_ready   (uart_rx_ready),
        .passthrough     (uart_passthrough),
        .ps_wen          (perip_wen && perip_addr == UART_STATUS_ADDR),
        .passthrough_req (uart_passthrough_req)
    );

    assign i2c_start = perip_wen && perip_addr == I2C_CTRL_ADDR &&
                       perip_wdata[0] && !i2c_busy;

    i2c_register_master #(
        .CLK_FREQ_HZ (200_000_000),
        .I2C_FREQ_HZ (100_000)
    ) i2c_master_inst (
        .clk            (clk),
        .rst            (rst),
        .start          (i2c_start),
        .read_not_write (perip_wdata[1]),
        .device_addr    (i2c_device_addr),
        .register_addr  (i2c_register_addr),
        .write_data     (i2c_write_data),
        .read_data      (i2c_read_data),
        .busy           (i2c_busy),
        .done           (i2c_done),
        .ack_error      (i2c_ack_error),
        .i2c_scl        (bme_scl),
        .i2c_sda        (bme_sda)
    );

endmodule
