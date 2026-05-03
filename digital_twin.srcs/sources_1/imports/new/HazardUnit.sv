module HazardUnit (
    input  logic [4:0] IF_ID_rs1,
    input  logic [4:0] IF_ID_rs2,
    input  logic [4:0] ID_EX_rd,
    input  logic       ID_EX_MemRead,
    input  logic       BranchTaken,
    output logic       Stall,
    output logic       Flush_IF_ID,
    output logic       Flush_ID_EX
);
    logic load_use_hazard;

    assign load_use_hazard = ID_EX_MemRead && (ID_EX_rd != 0) &&
                            ((ID_EX_rd == IF_ID_rs1) || (ID_EX_rd == IF_ID_rs2));

    assign Stall = load_use_hazard;

    assign Flush_IF_ID = BranchTaken;
    assign Flush_ID_EX = load_use_hazard || BranchTaken;

endmodule
