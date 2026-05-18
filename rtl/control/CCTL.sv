// =============================================================================
// CCTL.sv —— CSR 控制译码
//   位于 ID 级，识别四类 CSR/系统调用指令并产生 4 位独热控制信号 CSRControll：
//     bit0 csrrs / bit1 csrrw / bit2 ecall / bit3 mret
//   同时抽取指令中的 csr_idx 字段（[31:20]）供 CSR 模块定位寄存器。
// =============================================================================
module CCTL (
    input  logic [31:0] instr      ,                       // 当前 ID 级指令
    output logic [11:0] csr_idx    ,                       // CSR 寄存器索引
    output logic [3:0]  CSRControll                        // 独热 CSR 控制信号
);
    // 抽取 CSR 索引字段
    assign csr_idx = instr[31:20];

    // 四种 CSR/系统指令独立译码
    assign CSRControll[0] = (instr[6:0] == 7'b1110011) && (instr[14:12] == 3'b010); // csrrs
    assign CSRControll[1] = (instr[6:0] == 7'b1110011) && (instr[14:12] == 3'b001); // csrrw
    assign CSRControll[2] = (instr      == 32'h00000073);                            // ecall
    assign CSRControll[3] = (instr      == 32'h30200073);                            // mret
endmodule
