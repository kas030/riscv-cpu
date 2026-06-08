// =============================================================================
// mycpu_lsu.sv
//   Load/store unit boundary for the CPU memory stage. Address decoding remains
//   in perip_bridge; this module only drives the existing mycpu memory bus.
// =============================================================================
module mycpu_lsu #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] lsu_addr_i,
    input  logic [DATAWIDTH - 1:0] store_data_i,
    input  logic [2:0]             funct3_i,
    input  logic                   mem_write_i,
    input  logic [DATAWIDTH - 1:0] bus_rdata_i,

    output logic [DATAWIDTH - 1:0] bus_addr_o,
    output logic                   bus_wen_o,
    output logic [1:0]             bus_mask_o,
    output logic [DATAWIDTH - 1:0] bus_wdata_o,
    output logic [DATAWIDTH - 1:0] load_raw_o
);
    assign bus_addr_o  = lsu_addr_i;
    assign bus_wen_o   = mem_write_i;
    assign bus_mask_o  = funct3_i[1:0];
    assign bus_wdata_o = store_data_i;
    assign load_raw_o  = bus_rdata_i;
endmodule
