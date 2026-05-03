`timescale 1ns / 1ps

module myCPU_mem_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] perip_rdata,
    input  logic [DATAWIDTH - 1:0] MEM_pcadd4,
    input  logic [DATAWIDTH - 1:0] MEM_alu_result,
    input  logic [DATAWIDTH - 1:0] MEM_rR2_data,
    input  logic [DATAWIDTH - 1:0] MEM_imm,
    input  logic [DATAWIDTH - 1:0] MEM_csr_wb,
    input  logic [2:0]             MEM_MemToReg,
    input  logic [2:0]             MEM_funct3,
    input  logic                   MEM_MemWrite,
    output logic [DATAWIDTH - 1:0] perip_addr,
    output logic [DATAWIDTH - 1:0] perip_wdata,
    output logic [DATAWIDTH - 1:0] MEM_mdata,
    output logic [DATAWIDTH - 1:0] MEM_forward_data,
    output logic                   perip_wen,
    output logic [1:0]             perip_mask
);
    assign MEM_forward_data = (MEM_MemToReg == 3'b100) ? MEM_csr_wb :
                              (MEM_MemToReg == 3'b011) ? MEM_imm :
                              (MEM_MemToReg == 3'b000) ? MEM_pcadd4 :
                              MEM_alu_result;

    assign perip_addr  = MEM_alu_result;
    assign perip_wen   = MEM_MemWrite;
    assign perip_mask  = MEM_funct3[1:0];
    assign perip_wdata = MEM_rR2_data;

    Mask #(DATAWIDTH) mask_inst (
        .mask  (MEM_funct3),
        .dout  (perip_rdata),
        .mdata (MEM_mdata)
    );
endmodule
