`timescale 1ns / 1ps
// =============================================================================
// mycpu_ex_mem_reg.sv —— EX/MEM 流水线寄存器
//   - 把 EX 级算出的 alu_result / 前递后的 rR2 / pc+4 / csr_wb 等通路数据
//     以及 RegWrite / MemWrite / MemRead / MemToReg / funct3 等控制信号
//     锁存到 MEM 级
//   - 顺手把 pc+4 在这里算出锁存（MEM_pcadd4 = EX_pc + 4），避免后级再算
//   - 复位时控制信号清零，数据通路保持原值（不需要清，下次写入即覆盖）
// =============================================================================
module mycpu_ex_mem_reg #(
    parameter DATAWIDTH  = 32 ,
    parameter ADDR_WIDTH = 5
) (
    // ---- 输入：来自 EX 级 ----
    input  logic [DATAWIDTH - 1:0]  EX_pc            ,
    input  logic [DATAWIDTH - 1:0]  EX_alu_result    ,
    input  logic [DATAWIDTH - 1:0]  EX_mem_addr      ,
    input  logic [DATAWIDTH - 1:0]  EX_forward_B_out ,      // 前递后的 rs2，用作 store 写数据
    input  logic [DATAWIDTH - 1:0]  EX_imm           ,
    input  logic [DATAWIDTH - 1:0]  EX_csr_wb        ,
    input  logic [ADDR_WIDTH - 1:0] EX_rd            ,
    input  logic                    EX_RegWrite      ,
    input  logic                    EX_MemWrite      ,
    input  logic                    EX_MemRead       ,
    input  logic [2:0]              EX_MemToReg      ,
    input  logic [2:0]              EX_funct3        ,
    input  logic                    EX_cache_hit     ,
    input  logic [DATAWIDTH - 1:0]  EX_cache_data    ,
    input  logic                    clk              ,
    input  logic                    rst              ,
    input  logic                    en               ,
    input  logic                    Flush_EX_MEM     ,
    // ---- 输出：送往 MEM 级 ----
    output logic [DATAWIDTH - 1:0]  MEM_pcadd4       ,
    output logic [DATAWIDTH - 1:0]  MEM_alu_result   ,
    output logic [DATAWIDTH - 1:0]  MEM_perip_addr   ,
    (* keep = "true", max_fanout = 64 *)
    output logic [DATAWIDTH - 1:0]  MEM_perip_bus_addr,
    output logic [DATAWIDTH - 1:0]  MEM_rR2_data     ,
    output logic [DATAWIDTH - 1:0]  MEM_imm          ,
    output logic [DATAWIDTH - 1:0]  MEM_csr_wb       ,
    output logic [DATAWIDTH - 1:0]  MEM_forward_data ,
    output logic [ADDR_WIDTH - 1:0] MEM_rd           ,
    output logic [31:0]             MEM_rd_oh        ,
    output logic                    MEM_RegWrite     ,
    output logic                    MEM_MemWrite     ,
    output logic                    MEM_MemRead      ,
    output logic [2:0]              MEM_MemToReg     ,
    output logic [2:0]              MEM_funct3       ,
    output logic                    MEM_cache_hit    ,
    output logic [DATAWIDTH - 1:0]  MEM_cache_data
);
    logic [DATAWIDTH - 1:0] EX_pcadd4;

    assign EX_pcadd4 = EX_pc + 4;

    always_ff @(posedge clk) begin
        if (rst || Flush_EX_MEM) begin
            // 控制信号清零即可，数据通路下一拍会被覆盖
            MEM_RegWrite <= 1'b0;
            MEM_MemWrite <= 1'b0;
            MEM_MemRead  <= 1'b0;
            MEM_MemToReg <= '0;
            MEM_funct3   <= '0;
            MEM_rd_oh    <= 32'b0;
            MEM_cache_hit <= 1'b0;
        end else if (en) begin
            MEM_pcadd4     <= EX_pcadd4;                    // 顺手算 pc_reg+4 给 jal/jalr 写回用
            MEM_alu_result <= (EX_MemRead || EX_MemWrite) ? EX_mem_addr : EX_alu_result;
            MEM_perip_addr <= EX_mem_addr;                  // 独立访存地址副本，避免内部 alu 结果承担外部高扇出
            MEM_perip_bus_addr <= EX_mem_addr;              // 外设总线专用副本，和 CPU 本地判断解耦
            MEM_rR2_data   <= EX_forward_B_out;             // 注意是前递后的值
            MEM_imm        <= EX_imm;
            MEM_rd         <= EX_rd;
            MEM_rd_oh      <= (EX_RegWrite && (EX_rd != '0)) ? (32'b1 << EX_rd) : 32'b0;
            MEM_RegWrite   <= EX_RegWrite;
            MEM_MemWrite   <= EX_MemWrite;
            MEM_MemRead    <= EX_MemRead;
            MEM_MemToReg   <= EX_MemToReg;
            MEM_funct3     <= EX_funct3;
            MEM_csr_wb     <= EX_csr_wb;
            MEM_cache_hit  <= EX_cache_hit;
            MEM_cache_data <= EX_cache_data;
            MEM_forward_data <= (EX_MemToReg == 3'b100) ? EX_csr_wb    :
                                (EX_MemToReg == 3'b011) ? EX_imm       :
                                (EX_MemToReg == 3'b000) ? EX_pcadd4    :
                                (EX_MemRead || EX_MemWrite) ? EX_mem_addr :
                                                           EX_alu_result;
        end else begin
            // EX 级多周期指令未完成时保持 EX/MEM，不让半成品结果进入 MEM。
        end
    end
endmodule
