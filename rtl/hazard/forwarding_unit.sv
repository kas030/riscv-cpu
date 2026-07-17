// =============================================================================
// forwarding_unit.sv -- EX stage forwarding data mux
//   ForwardA_sel / ForwardB_sel are calculated one cycle earlier in ID and
//   registered together with the consumer instruction.  The EX critical path
//   therefore contains only the data mux, not rd comparisons and priority
//   selection.
//
//     3'd0  use the value read from reg_file
//     3'd1/3'd4  use the consumer-local ready operand captured from MEM2
//     3'd2/3'd5  forward from MEM1 lane 0/lane 1
//     3'd3/3'd6  forward from MEM2 lane 0/lane 1
//     3'd7       use the consumer-local raw word from a late lw miss
// =============================================================================
module forwarding_unit (
    input  logic [31:0] ID_EX_data1,
    input  logic [31:0] ID_EX_data2,
    input  logic [31:0] EX_MEM_data0,
    input  logic [31:0] EX_MEM_data1,
    input  logic [31:0] MEM2_data0,
    input  logic [31:0] MEM2_data1,
    input  logic [31:0] LATE_data1,
    input  logic [31:0] LATE_data2,
    input  logic [31:0] LATE_load_word,
    input  logic [2:0]  ForwardA_sel,
    input  logic [2:0]  ForwardB_sel,
    output logic [31:0] ForwardAData,
    output logic [31:0] ForwardBData
);
    function automatic logic [31:0] select_data(
        input logic [2:0]  sel,
        input logic [31:0] original,
        input logic [31:0] late_data,
        input logic [31:0] late_load_word
    );
        begin
            case (sel)
                3'd1: select_data = late_data;
                3'd2: select_data = EX_MEM_data0;
                3'd3: select_data = MEM2_data0;
                3'd4: select_data = late_data;
                3'd5: select_data = EX_MEM_data1;
                3'd6: select_data = MEM2_data1;
                3'd7: select_data = late_load_word;
                default: select_data = original;
            endcase
        end
    endfunction

    always_comb begin
        ForwardAData = select_data(ForwardA_sel, ID_EX_data1,
                                   LATE_data1, LATE_load_word);
        ForwardBData = select_data(ForwardB_sel, ID_EX_data2,
                                   LATE_data2, LATE_load_word);
    end
endmodule
