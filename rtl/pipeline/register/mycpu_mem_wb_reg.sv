`timescale 1ns / 1ps
// =============================================================================
// mycpu_mem_wb_reg.sv —— MEM/WB 流水线寄存器
//   - 把 MEM 级所有可能被写回的候选 (pcadd4 / alu_result / mdata / imm /
//     csr_wb) 以及目标寄存器号、RegWrite/MemToReg 控制信号锁存到 WB 级
//   - 复位时控制信号清零，数据通路无需清零
// =============================================================================
module mycpu_mem_wb_reg #(
    parameter DATAWIDTH  = 32 ,
    parameter ADDR_WIDTH = 5
) (
    // ---- 输入：来自 MEM 级 ----
    input  logic [DATAWIDTH - 1:0]  MEM_pcadd4     ,
    input  logic [DATAWIDTH - 1:0]  MEM_alu_result ,
    input  logic [DATAWIDTH - 1:0]  MEM_mdata      ,
    input  logic [DATAWIDTH - 1:0]  MEM_imm        ,
    input  logic [DATAWIDTH - 1:0]  MEM_csr_wb     ,
    input  logic [ADDR_WIDTH - 1:0] MEM_rd         ,
    input  logic [31:0]             MEM_rd_oh      ,
    input  logic                    MEM_RegWrite   ,
    input  logic [2:0]              MEM_MemToReg   ,
    input  logic [2:0]              MEM_funct3     ,
    input  logic                    MEM_bram_access,
    input  logic                    clk            ,
    input  logic                    rst            ,
    input  logic                    Flush_MEM_WB   ,
    // ---- 输出：送往 WB 级 ----
    output logic [DATAWIDTH - 1:0]  WB_pcadd4      ,
    output logic [DATAWIDTH - 1:0]  WB_alu_result  ,
    output logic [DATAWIDTH - 1:0]  WB_mdata       ,
    output logic [DATAWIDTH - 1:0]  WB_imm         ,
    output logic [DATAWIDTH - 1:0]  WB_csr_wb      ,
    output logic [ADDR_WIDTH - 1:0] WB_rd          ,
    output logic [31:0]             WB_rd_oh       ,
    output logic                    WB_RegWrite    ,
    output logic [2:0]              WB_MemToReg    ,
    output logic [4:0]              WB_wb_sel      ,
    output logic [2:0]              WB_funct3      ,
    output logic                    WB_bram_access
);
    always_ff @(posedge clk) begin
        if (rst || Flush_MEM_WB) begin
            WB_RegWrite <= 1'b0;
            WB_MemToReg <= '0;
            WB_wb_sel   <= '0;
            WB_rd_oh    <= 32'b0;
            WB_funct3   <= '0;
            WB_bram_access <= 1'b0;
        end else begin
            WB_pcadd4     <= MEM_pcadd4;
            WB_alu_result <= MEM_alu_result;
            WB_mdata      <= MEM_mdata;
            WB_imm        <= MEM_imm;
            WB_rd         <= MEM_rd;
            WB_rd_oh      <= MEM_rd_oh;
            WB_RegWrite   <= MEM_RegWrite;
            WB_MemToReg   <= MEM_MemToReg;
            case (MEM_MemToReg)
                3'b000: WB_wb_sel <= 5'b00001;
                3'b001: WB_wb_sel <= 5'b00010;
                3'b010: WB_wb_sel <= 5'b00100;
                3'b011: WB_wb_sel <= 5'b01000;
                3'b100: WB_wb_sel <= 5'b10000;
                default: WB_wb_sel <= '0;
            endcase
            WB_csr_wb     <= MEM_csr_wb;
            WB_funct3     <= MEM_funct3;
            WB_bram_access <= MEM_bram_access;
        end
    end
endmodule
