// =============================================================================
// load_mask.sv - Load sign/zero extension for RV32I
//   The DRAM driver has already selected the addressed byte/halfword/word and
//   zero-extended it into dout. This stage applies signed extension for lb/lh.
// =============================================================================
module load_mask #(
    parameter DATAWIDTH = 32
)(
    input  logic [2:0]             mask,
    input  logic [DATAWIDTH - 1:0] dout,
    output logic [DATAWIDTH - 1:0] mdata
);
    logic sel_lb, sel_lh, sel_other;

    assign sel_lb    = (mask == 3'b000);
    assign sel_lh    = (mask == 3'b001);
    assign sel_other = ~(sel_lh | sel_lb);

    assign mdata = {DATAWIDTH{sel_lb   }} & {{24{dout[ 7]}}, dout[ 7:0]} |
                   {DATAWIDTH{sel_lh   }} & {{16{dout[15]}}, dout[15:0]} |
                   {DATAWIDTH{sel_other}} & dout;
endmodule
