// =============================================================================
// forwarding_unit.sv -- EX stage RAW forwarding selector
//   Produces the two 2-bit forwarding selects used by mycpu_ex_stage:
//     2'b10  forward from EX/MEM
//     2'b11  forward from MEM2
//     2'b01  forward from MEM/WB
//     2'b00  use the value read from reg_file
//   Priority remains EX/MEM > MEM2 > MEM/WB > reg_file.  The match logic uses
//   5-bit rd equality instead of rd_oh[rs] dynamic indexing to shorten the
//   rs -> forwarding-select path at 200 MHz.
// =============================================================================
module forwarding_unit (
    input  logic [4:0] ID_EX_rs1,
    input  logic [4:0] ID_EX_rs2,
    input  logic [4:0] EX_MEM_rd,
    input  logic       EX_MEM_valid,
    input  logic [4:0] MEM2_rd,
    input  logic       MEM2_valid,
    input  logic [4:0] MEM_WB_rd,
    input  logic       MEM_WB_valid,
    output logic [1:0] ForwardA,
    output logic [1:0] ForwardB
);
    logic hit_ex_mem_rs1, hit_mem2_rs1, hit_mem_wb_rs1;
    logic hit_ex_mem_rs2, hit_mem2_rs2, hit_mem_wb_rs2;

    assign hit_ex_mem_rs1 = EX_MEM_valid && (EX_MEM_rd == ID_EX_rs1);
    assign hit_mem2_rs1   = MEM2_valid   && (MEM2_rd   == ID_EX_rs1);
    assign hit_mem_wb_rs1 = MEM_WB_valid && (MEM_WB_rd == ID_EX_rs1);
    assign hit_ex_mem_rs2 = EX_MEM_valid && (EX_MEM_rd == ID_EX_rs2);
    assign hit_mem2_rs2   = MEM2_valid   && (MEM2_rd   == ID_EX_rs2);
    assign hit_mem_wb_rs2 = MEM_WB_valid && (MEM_WB_rd == ID_EX_rs2);

    always_comb begin
        if (hit_ex_mem_rs1) begin
            ForwardA = 2'b10;
        end else if (hit_mem2_rs1) begin
            ForwardA = 2'b11;
        end else if (hit_mem_wb_rs1) begin
            ForwardA = 2'b01;
        end else begin
            ForwardA = 2'b00;
        end
    end

    always_comb begin
        if (hit_ex_mem_rs2) begin
            ForwardB = 2'b10;
        end else if (hit_mem2_rs2) begin
            ForwardB = 2'b11;
        end else if (hit_mem_wb_rs2) begin
            ForwardB = 2'b01;
        end else begin
            ForwardB = 2'b00;
        end
    end
endmodule
