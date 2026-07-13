// =============================================================================
// forwarding_unit.sv -- EX stage RAW forwarding selector
//   Produces two 3-bit forwarding selects used by the dual-issue EX lanes:
//     3'd0  use the value read from reg_file
//     3'd1  forward from MEM/WB lane 0
//     3'd2  forward from EX/MEM lane 0
//     3'd3  forward from MEM2 lane 0
//     3'd4  forward from MEM/WB lane 1
//     3'd5  forward from EX/MEM lane 1
//     3'd6  forward from MEM2 lane 1
//   Priority is EX/MEM > MEM2 > MEM/WB, and lane 1 wins within the same stage
//   because it is the younger instruction in an in-order dual-issue bundle.
// =============================================================================
module forwarding_unit (
    input  logic [4:0] ID_EX_rs1,
    input  logic [4:0] ID_EX_rs2,
    input  logic [31:0] ID_EX_data1,
    input  logic [31:0] ID_EX_data2,
    input  logic [4:0] EX_MEM_rd0,
    input  logic       EX_MEM_valid0,
    input  logic [4:0] EX_MEM_rd1,
    input  logic       EX_MEM_valid1,
    input  logic [4:0] MEM2_rd0,
    input  logic       MEM2_valid0,
    input  logic [4:0] MEM2_rd1,
    input  logic       MEM2_valid1,
    input  logic [4:0] MEM_WB_rd0,
    input  logic       MEM_WB_valid0,
    input  logic [4:0] MEM_WB_rd1,
    input  logic       MEM_WB_valid1,
    input  logic [31:0] EX_MEM_data0,
    input  logic [31:0] EX_MEM_data1,
    input  logic [31:0] MEM2_data0,
    input  logic [31:0] MEM2_data1,
    input  logic [31:0] MEM_WB_data0,
    input  logic [31:0] MEM_WB_data1,
    output logic [2:0] ForwardA,
    output logic [2:0] ForwardB,
    output logic [31:0] ForwardAData,
    output logic [31:0] ForwardBData
);
    function automatic logic [2:0] select_forward(input logic [4:0] rs);
        begin
            if (EX_MEM_valid1 && (EX_MEM_rd1 == rs)) begin
                select_forward = 3'd5;
            end else if (EX_MEM_valid0 && (EX_MEM_rd0 == rs)) begin
                select_forward = 3'd2;
            end else if (MEM2_valid1 && (MEM2_rd1 == rs)) begin
                select_forward = 3'd6;
            end else if (MEM2_valid0 && (MEM2_rd0 == rs)) begin
                select_forward = 3'd3;
            end else if (MEM_WB_valid1 && (MEM_WB_rd1 == rs)) begin
                select_forward = 3'd4;
            end else if (MEM_WB_valid0 && (MEM_WB_rd0 == rs)) begin
                select_forward = 3'd1;
            end else begin
                select_forward = 3'd0;
            end
        end
    endfunction

    function automatic logic [31:0] select_data(
        input logic [4:0] rs,
        input logic [31:0] original
    );
        begin
            if (EX_MEM_valid1 && (EX_MEM_rd1 == rs)) begin
                select_data = EX_MEM_data1;
            end else if (EX_MEM_valid0 && (EX_MEM_rd0 == rs)) begin
                select_data = EX_MEM_data0;
            end else if (MEM2_valid1 && (MEM2_rd1 == rs)) begin
                select_data = MEM2_data1;
            end else if (MEM2_valid0 && (MEM2_rd0 == rs)) begin
                select_data = MEM2_data0;
            end else if (MEM_WB_valid1 && (MEM_WB_rd1 == rs)) begin
                select_data = MEM_WB_data1;
            end else if (MEM_WB_valid0 && (MEM_WB_rd0 == rs)) begin
                select_data = MEM_WB_data0;
            end else begin
                select_data = original;
            end
        end
    endfunction

    always_comb begin
        ForwardA = select_forward(ID_EX_rs1);
        ForwardAData = select_data(ID_EX_rs1, ID_EX_data1);
    end

    always_comb begin
        ForwardB = select_forward(ID_EX_rs2);
        ForwardBData = select_data(ID_EX_rs2, ID_EX_data2);
    end
endmodule
