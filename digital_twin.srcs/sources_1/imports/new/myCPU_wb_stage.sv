`timescale 1ns / 1ps
// =============================================================================
// myCPU_wb_stage.sv —— WB（写回）级
//   根据 WB_MemToReg（一热 3 位编码）把 5 个候选数据中的一个作为最终写回值：
//     3'b000 pcadd4     —— jal/jalr 写 PC+4
//     3'b001 alu_result —— 一般 R/I 型、auipc
//     3'b010 mdata      —— load
//     3'b011 imm        —— lui
//     3'b100 csr_wb     —— csrrs / csrrw 等
//   最终 WB_wdata 写回寄存器堆，同时也作为 ForwardingUnit 的候选源之一。
// =============================================================================
module myCPU_wb_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] WB_pcadd4     ,
    input  logic [DATAWIDTH - 1:0] WB_alu_result ,
    input  logic [DATAWIDTH - 1:0] WB_mdata      ,
    input  logic [DATAWIDTH - 1:0] WB_imm        ,
    input  logic [DATAWIDTH - 1:0] WB_csr_wb     ,
    input  logic [2:0]             WB_MemToReg   ,
    output logic [DATAWIDTH - 1:0] WB_wdata
);
    // 5 路 key-value 多路选择，按 WB_MemToReg 选择对应候选
    MuxKey #(5, 3, DATAWIDTH) u_mux_wb (WB_wdata, WB_MemToReg, {
        3'b000, WB_pcadd4    ,
        3'b001, WB_alu_result,
        3'b010, WB_mdata     ,
        3'b011, WB_imm       ,
        3'b100, WB_csr_wb
    });
endmodule
