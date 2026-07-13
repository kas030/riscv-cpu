`timescale 1ns / 1ps
// =============================================================================
// mycpu_wb_stage.sv —— WB（写回）级
//   根据 MEM/WB 寄存的一热选择信号把 5 个候选数据中的一个作为最终写回值：
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
    input  logic [4:0]             WB_wb_sel     ,
    input  logic [2:0]             WB_funct3     ,
    input  logic                   WB_bram_access,
    output logic [DATAWIDTH - 1:0] WB_wdata
);
    logic [DATAWIDTH - 1:0] WB_load_data;

    function automatic logic [DATAWIDTH - 1:0] format_load_data(
        input logic [DATAWIDTH - 1:0] word,
        input logic [2:0] funct3,
        input logic [1:0] offset,
        input logic bram_access
    );
        logic [7:0] selected_byte;
        logic [15:0] selected_half;
        begin
            if (bram_access) begin
                case (offset)
                    2'b00: selected_byte = word[7:0];
                    2'b01: selected_byte = word[15:8];
                    2'b10: selected_byte = word[23:16];
                    default: selected_byte = word[31:24];
                endcase
                selected_half = offset[1] ? word[31:16] : word[15:0];
            end else begin
                selected_byte = word[7:0];
                selected_half = word[15:0];
            end

            case (funct3)
                3'b000: format_load_data = {{24{selected_byte[7]}}, selected_byte};
                3'b001: format_load_data = {{16{selected_half[15]}}, selected_half};
                3'b100: format_load_data = {24'b0, selected_byte};
                3'b101: format_load_data = {16'b0, selected_half};
                default: format_load_data = word;
            endcase
        end
    endfunction

    // 在 WB 一次完成 load 字内选择与扩展，避免 miss load 前递穿过两级 mux。
    assign WB_load_data = format_load_data(WB_mdata, WB_funct3,
                                           WB_alu_result[1:0], WB_bram_access);

    assign WB_wdata = ({DATAWIDTH{WB_wb_sel[0]}} & WB_pcadd4) |
                      ({DATAWIDTH{WB_wb_sel[1]}} & WB_alu_result) |
                      ({DATAWIDTH{WB_wb_sel[2]}} & WB_load_data) |
                      ({DATAWIDTH{WB_wb_sel[3]}} & WB_imm) |
                      ({DATAWIDTH{WB_wb_sel[4]}} & WB_csr_wb);
endmodule
