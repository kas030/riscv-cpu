// =============================================================================
// forwarding_unit.sv -- EX stage forwarding data mux
//   ForwardA_sel / ForwardB_sel are calculated one cycle earlier in ID and
//   registered together with the consumer instruction.  The EX critical path
//   therefore contains only the data mux, not rd comparisons and priority
//   selection.
//
//     3'd0       use the value already resolved at the ID/EX boundary
//     3'd2/3'd5  forward from MEM1 lane 0/lane 1
// =============================================================================
module forwarding_unit (
    input  logic [31:0] ID_EX_data1,
    input  logic [31:0] ID_EX_data2,
    input  logic [31:0] EX_MEM_data0,
    input  logic [31:0] EX_MEM_data1,
    input  logic [2:0]  ForwardA_sel,
    input  logic [2:0]  ForwardB_sel,
    output logic [31:0] ForwardAData,
    output logic [31:0] ForwardBData
);
    function automatic logic [31:0] select_data(
        input logic [2:0]  sel,
        input logic [31:0] original
    );
        begin
            case (sel)
                3'd2: select_data = EX_MEM_data0;
                3'd5: select_data = EX_MEM_data1;
                default: select_data = original;
            endcase
        end
    endfunction

    always_comb begin
        ForwardAData = select_data(ForwardA_sel, ID_EX_data1);
        ForwardBData = select_data(ForwardB_sel, ID_EX_data2);
    end
endmodule
