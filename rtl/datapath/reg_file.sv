// =============================================================================
// reg_file.sv —— 32 项通用寄存器堆（x0~x31）
//   - 写口：WB 级在时钟上升沿把 wdata 写入 waddr，wen=1 且 waddr!=0；
//     x0 永远为 0，写 x0 直接屏蔽。
//   - 读口：双口异步读，ID 级直接拿到 rR1/rR2 数据。
//   - WB-ID 内部前递：当本周期 WB 正在写的目标恰好是 ID 要读的同一寄存器时，
//     直接把 wdata 旁路给读输出，省去一条 MEM-WB 前递路径。
// =============================================================================
module reg_file #(
    parameter   ADDR_WIDTH = 5  ,
    parameter   DATAWIDTH  = 32
)(
    input  logic                    clk      ,             // 时钟
    input  logic                    rst      ,             // 异步复位（复位后全部清零）
    // 写口（WB 级）
    input  logic                    wen      ,             // 写使能
    input  logic [ADDR_WIDTH - 1:0] waddr    ,             // 写地址（5 位 → 32 项）
    input  logic [DATAWIDTH  - 1:0] wdata    ,             // 写数据
    // 读口（ID 级，双口异步）
    input  logic [ADDR_WIDTH - 1:0] rR1      ,             // 读端口 1 地址
    input  logic [ADDR_WIDTH - 1:0] rR2      ,             // 读端口 2 地址
    output logic [DATAWIDTH  - 1:0] rR1_data ,             // 读端口 1 数据
    output logic [DATAWIDTH  - 1:0] rR2_data               // 读端口 2 数据
);
    // 32 项寄存器存储体，会被 Vivado 综合为 LUTRAM
    logic [DATAWIDTH - 1:0] xreg [31:0];

    // 同步写：x0 不可写
    always_ff @(posedge clk, posedge rst) begin
        if (rst) begin
            for (int k = 0; k < 32; k++) xreg[k] <= '0;    // 复位全部清零
        end
        else if (wen & (waddr != 5'd0)) begin
            xreg[waddr] <= wdata;                          // 普通寄存器写入
        end
    end

    // 异步读 + WB-ID 内部前递（同周期写读旁路）
    assign rR1_data = (wen && (waddr == rR1) && (rR1 != 0)) ? wdata : xreg[rR1];
    assign rR2_data = (wen && (waddr == rR2) && (rR2 != 0)) ? wdata : xreg[rR2];
endmodule
