`timescale 1ns / 1ps

module myCPU_wb_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] WB_pcadd4,
    input  logic [DATAWIDTH - 1:0] WB_alu_result,
    input  logic [DATAWIDTH - 1:0] WB_mdata,
    input  logic [DATAWIDTH - 1:0] WB_imm,
    input  logic [DATAWIDTH - 1:0] WB_csr_wb,
    input  logic [2:0]             WB_MemToReg,
    output logic [DATAWIDTH - 1:0] WB_wdata
);
    MuxKey #(5, 3, DATAWIDTH) mux_wb (WB_wdata, WB_MemToReg, {
        3'b000, WB_pcadd4,
        3'b001, WB_alu_result,
        3'b010, WB_mdata,
        3'b011, WB_imm,
        3'b100, WB_csr_wb
    });
endmodule
