`timescale 1ns / 1ps

module myCPU_ex_mem_reg #(
    parameter DATAWIDTH = 32,
    parameter ADDR_WIDTH = 5
) (
    input  logic [DATAWIDTH - 1:0] EX_pc,
    input  logic [DATAWIDTH - 1:0] EX_alu_result,
    input  logic [DATAWIDTH - 1:0] EX_forward_B_out,
    input  logic [DATAWIDTH - 1:0] EX_imm,
    input  logic [DATAWIDTH - 1:0] EX_csr_wb,
    input  logic [ADDR_WIDTH - 1:0] EX_rd,
    input  logic                   EX_RegWrite,
    input  logic                   EX_MemWrite,
    input  logic                   EX_MemRead,
    input  logic                   EX_isCSR,
    input  logic [2:0]             EX_MemToReg,
    input  logic [2:0]             EX_funct3,
    input  logic                   clk,
    input  logic                   rst,
    output logic [DATAWIDTH - 1:0] MEM_pcadd4,
    output logic [DATAWIDTH - 1:0] MEM_alu_result,
    output logic [DATAWIDTH - 1:0] MEM_rR2_data,
    output logic [DATAWIDTH - 1:0] MEM_imm,
    output logic [DATAWIDTH - 1:0] MEM_csr_wb,
    output logic [ADDR_WIDTH - 1:0] MEM_rd,
    output logic                   MEM_RegWrite,
    output logic                   MEM_MemWrite,
    output logic                   MEM_MemRead,
    output logic                   MEM_isCSR,
    output logic [2:0]             MEM_MemToReg,
    output logic [2:0]             MEM_funct3
);
    always_ff @(posedge clk) begin
        if (rst) begin
            MEM_RegWrite <= 1'b0;
            MEM_MemWrite <= 1'b0;
            MEM_MemRead  <= 1'b0;
            MEM_isCSR    <= 1'b0;
            MEM_MemToReg <= '0;
            MEM_funct3   <= '0;
        end else begin
            MEM_pcadd4     <= EX_pc + 4;
            MEM_alu_result <= EX_alu_result;
            MEM_rR2_data   <= EX_forward_B_out;
            MEM_imm        <= EX_imm;
            MEM_rd         <= EX_rd;
            MEM_RegWrite   <= EX_RegWrite;
            MEM_MemWrite   <= EX_MemWrite;
            MEM_MemRead    <= EX_MemRead;
            MEM_isCSR      <= EX_isCSR;
            MEM_MemToReg   <= EX_MemToReg;
            MEM_funct3     <= EX_funct3;
            MEM_csr_wb     <= EX_csr_wb;
        end
    end
endmodule
