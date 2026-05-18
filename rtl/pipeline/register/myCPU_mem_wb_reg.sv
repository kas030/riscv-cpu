`timescale 1ns / 1ps
// =============================================================================
// myCPU_mem_wb_reg.sv —— MEM/WB 流水线寄存器
//   - 把 MEM 级所有可能被写回的候选 (pcadd4 / alu_result / mdata / imm /
//     csr_wb) 以及目标寄存器号、RegWrite/MemToReg 控制信号锁存到 WB 级
//   - 复位时控制信号清零，数据通路无需清零
// =============================================================================
module myCPU_mem_wb_reg #(
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
    input  logic                    MEM_RegWrite   ,
    input  logic [2:0]              MEM_MemToReg   ,
    input  logic                    clk            ,
    input  logic                    rst            ,
    // ---- 输出：送往 WB 级 ----
    output logic [DATAWIDTH - 1:0]  WB_pcadd4      ,
    output logic [DATAWIDTH - 1:0]  WB_alu_result  ,
    output logic [DATAWIDTH - 1:0]  WB_mdata       ,
    output logic [DATAWIDTH - 1:0]  WB_imm         ,
    output logic [DATAWIDTH - 1:0]  WB_csr_wb      ,
    output logic [ADDR_WIDTH - 1:0] WB_rd          ,
    output logic                    WB_RegWrite    ,
    output logic [2:0]              WB_MemToReg
);
    always_ff @(posedge clk) begin
        if (rst) begin
            WB_RegWrite <= 1'b0;
            WB_MemToReg <= '0;
        end else begin
            WB_pcadd4     <= MEM_pcadd4;
            WB_alu_result <= MEM_alu_result;
            WB_mdata      <= MEM_mdata;
            WB_imm        <= MEM_imm;
            WB_rd         <= MEM_rd;
            WB_RegWrite   <= MEM_RegWrite;
            WB_MemToReg   <= MEM_MemToReg;
            WB_csr_wb     <= MEM_csr_wb;
        end
    end
endmodule
