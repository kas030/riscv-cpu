`timescale 1ns / 1ps
// =============================================================================
// mycpu_mem1_mem2_reg.sv —— MEM1/MEM2 流水线寄存器
//   - MEM1 发起外设/BRAM 访问，MEM2 对齐写回元数据与读返回数据。
//   - BRAM 为同步读，MEM2 不锁存当拍 perip_rdata，而是在下一拍送 MEM/WB
//     时使用已经稳定的总线返回值。
//   - MMIO 读为组合返回，必须在 MEM1 请求周期锁存，避免下一拍地址变化。
// =============================================================================
module mycpu_mem1_mem2_reg #(
    parameter DATAWIDTH  = 32 ,
    parameter ADDR_WIDTH = 5
) (
    input  logic [DATAWIDTH - 1:0]  MEM_pcadd4       ,
    input  logic [DATAWIDTH - 1:0]  MEM_alu_result   ,
    input  logic [DATAWIDTH - 1:0]  MEM_mdata        ,
    input  logic [DATAWIDTH - 1:0]  MEM_imm          ,
    input  logic [DATAWIDTH - 1:0]  MEM_csr_wb       ,
    input  logic [ADDR_WIDTH - 1:0] MEM_rd           ,
    input  logic [31:0]             MEM_rd_oh        ,
    input  logic                    MEM_RegWrite     ,
    input  logic                    MEM_MemRead      ,
    input  logic [2:0]              MEM_MemToReg     ,
    input  logic [2:0]              MEM_funct3       ,
    input  logic                    MEM_bram_access  ,
    input  logic                    clk              ,
    input  logic                    rst              ,

    output logic [DATAWIDTH - 1:0]  MEM2_pcadd4      ,
    output logic [DATAWIDTH - 1:0]  MEM2_alu_result  ,
    output logic [DATAWIDTH - 1:0]  MEM2_mmio_mdata  ,
    output logic [DATAWIDTH - 1:0]  MEM2_imm         ,
    output logic [DATAWIDTH - 1:0]  MEM2_csr_wb      ,
    output logic [ADDR_WIDTH - 1:0] MEM2_rd          ,
    output logic [31:0]             MEM2_rd_oh       ,
    output logic                    MEM2_RegWrite    ,
    output logic                    MEM2_MemRead     ,
    output logic [2:0]              MEM2_MemToReg    ,
    output logic [2:0]              MEM2_funct3      ,
    output logic                    MEM2_bram_access
);
    always_ff @(posedge clk) begin
        if (rst) begin
            MEM2_RegWrite    <= 1'b0;
            MEM2_MemRead     <= 1'b0;
            MEM2_MemToReg    <= '0;
            MEM2_funct3      <= '0;
            MEM2_rd_oh       <= 32'b0;
            MEM2_bram_access <= 1'b0;
        end else begin
            MEM2_pcadd4      <= MEM_pcadd4;
            MEM2_alu_result  <= MEM_alu_result;
            MEM2_mmio_mdata  <= MEM_mdata;
            MEM2_imm         <= MEM_imm;
            MEM2_csr_wb      <= MEM_csr_wb;
            MEM2_rd          <= MEM_rd;
            MEM2_rd_oh       <= MEM_rd_oh;
            MEM2_RegWrite    <= MEM_RegWrite;
            MEM2_MemRead     <= MEM_MemRead;
            MEM2_MemToReg    <= MEM_MemToReg;
            MEM2_funct3      <= MEM_funct3;
            MEM2_bram_access <= MEM_bram_access;
        end
    end
endmodule
