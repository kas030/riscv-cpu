// =============================================================================
// ForwardingUnit.sv —— 数据冒险前递选择
//   为 EX 级的 ALU 两个输入端各产生一个 2 位选择码：
//     2'b10  从 EX/MEM 流水寄存器前递（最近一拍写回的目标）
//     2'b01  从 MEM/WB 流水寄存器前递（再前一拍）
//     2'b00  无前递，使用寄存器堆原始读出值
//   优先级：EX/MEM > MEM/WB > 寄存器堆，因为越近的指令值越新。
//   x0 永远为 0，命中 rd==0 不视为冒险。
// =============================================================================
module ForwardingUnit (
    input  logic [4:0] ID_EX_rs1       ,                    // EX 级源寄存器 1
    input  logic [4:0] ID_EX_rs2       ,                    // EX 级源寄存器 2
    input  logic [4:0] EX_MEM_rd       ,                    // EX/MEM 写回目标
    input  logic       EX_MEM_RegWrite ,                    // EX/MEM 是否写回
    input  logic [4:0] MEM_WB_rd       ,                    // MEM/WB 写回目标
    input  logic       MEM_WB_RegWrite ,                    // MEM/WB 是否写回
    output logic [1:0] ForwardA        ,                    // ALU A 端前递选择
    output logic [1:0] ForwardB                             // ALU B 端前递选择
);
    // A 端前递：EX/MEM 优先，其次 MEM/WB
    always_comb begin
        if      (EX_MEM_RegWrite && (EX_MEM_rd != 5'd0) && (EX_MEM_rd == ID_EX_rs1))
            ForwardA = 2'b10;
        else if (MEM_WB_RegWrite && (MEM_WB_rd != 5'd0) && (MEM_WB_rd == ID_EX_rs1))
            ForwardA = 2'b01;
        else
            ForwardA = 2'b00;
    end

    // B 端前递：同上
    always_comb begin
        if      (EX_MEM_RegWrite && (EX_MEM_rd != 5'd0) && (EX_MEM_rd == ID_EX_rs2))
            ForwardB = 2'b10;
        else if (MEM_WB_RegWrite && (MEM_WB_rd != 5'd0) && (MEM_WB_rd == ID_EX_rs2))
            ForwardB = 2'b01;
        else
            ForwardB = 2'b00;
    end
endmodule
