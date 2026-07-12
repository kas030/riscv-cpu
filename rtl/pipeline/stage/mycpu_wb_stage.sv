`timescale 1ns / 1ps
// =============================================================================
// mycpu_wb_stage.sv —— WB（写回）级
//   根据 WB_MemToReg（一热 3 位编码）把 5 个候选数据中的一个作为最终写回值：
//     3'b000 pcadd4     —— jal/jalr 写 pc_reg+4
//     3'b001 alu_result —— 一般 R/I 型、auipc
//     3'b010 mdata      —— load
//     3'b011 imm        —— lui
//     3'b100 csr_wb     —— csrrs / csrrw 等
//   最终 WB_wdata 写回寄存器堆，同时也作为 forwarding_unit 的候选源之一。
// =============================================================================
module mycpu_wb_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] WB_pcadd4     ,
    input  logic [DATAWIDTH - 1:0] WB_alu_result ,
    input  logic [DATAWIDTH - 1:0] WB_mdata      ,
    input  logic [DATAWIDTH - 1:0] WB_imm        ,
    input  logic [DATAWIDTH - 1:0] WB_csr_wb     ,
    input  logic [2:0]             WB_MemToReg   ,
    input  logic [2:0]             WB_funct3     ,
    input  logic                   WB_bram_access,
    output logic [DATAWIDTH - 1:0] WB_wdata
);
    logic [DATAWIDTH - 1:0] WB_load_data;
    logic [DATAWIDTH - 1:0] WB_load_raw;

    function automatic logic [DATAWIDTH - 1:0] select_load_raw(
        input logic [DATAWIDTH - 1:0] word,
        input logic [2:0] funct3,
        input logic [1:0] offset
    );
        begin
            case (funct3[1:0])
                2'b00: begin
                    case (offset)
                        2'b00: select_load_raw = {24'b0, word[7:0]};
                        2'b01: select_load_raw = {24'b0, word[15:8]};
                        2'b10: select_load_raw = {24'b0, word[23:16]};
                        default: select_load_raw = {24'b0, word[31:24]};
                    endcase
                end
                2'b01: select_load_raw = offset[1] ? {16'b0, word[31:16]} :
                                                    {16'b0, word[15:0]};
                default: select_load_raw = word;
            endcase
        end
    endfunction

    assign WB_load_raw = WB_bram_access ?
                         select_load_raw(WB_mdata, WB_funct3,
                                         WB_alu_result[1:0]) : WB_mdata;

    // load 的符号扩展放到 WB 级，切断 MEM 级 perip_rdata 到 MEM/WB 锁存端的组合逻辑
    load_mask #(DATAWIDTH) u_load_mask (
        .mask  (WB_funct3    ),
        .dout  (WB_load_raw  ),
        .mdata (WB_load_data )
    );

    // 5 路 key-value 多路选择，按 WB_MemToReg 选择对应候选
    mux_key #(5, 3, DATAWIDTH) u_wb_mux (WB_wdata, WB_MemToReg, {
        3'b000, WB_pcadd4    ,
        3'b001, WB_alu_result,
        3'b010, WB_load_data ,
        3'b011, WB_imm       ,
        3'b100, WB_csr_wb
    });
endmodule
