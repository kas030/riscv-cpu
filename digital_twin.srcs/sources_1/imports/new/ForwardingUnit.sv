module ForwardingUnit (
    input  logic [4:0] ID_EX_rs1,
    input  logic [4:0] ID_EX_rs2,
    input  logic [4:0] EX_MEM_rd,
    input  logic       EX_MEM_RegWrite,
    input  logic [4:0] MEM_WB_rd,
    input  logic       MEM_WB_RegWrite,
    output logic [1:0] ForwardA,
    output logic [1:0] ForwardB
);
    always_comb begin
        if (EX_MEM_RegWrite && (EX_MEM_rd != 0) && (EX_MEM_rd == ID_EX_rs1))
            ForwardA = 2'b10;
        else if (MEM_WB_RegWrite && (MEM_WB_rd != 0) && (MEM_WB_rd == ID_EX_rs1))
            ForwardA = 2'b01;
        else
            ForwardA = 2'b00;
    end

    always_comb begin
        if (EX_MEM_RegWrite && (EX_MEM_rd != 0) && (EX_MEM_rd == ID_EX_rs2))
            ForwardB = 2'b10;
        else if (MEM_WB_RegWrite && (MEM_WB_rd != 0) && (MEM_WB_rd == ID_EX_rs2))
            ForwardB = 2'b01;
        else
            ForwardB = 2'b00;
    end
endmodule
