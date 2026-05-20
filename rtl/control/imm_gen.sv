// =============================================================================
// imm_gen.sv —— 立即数生成器
//   位于 ID 级，从 32 位指令中按指令格式抽取并符号扩展立即数：
//     I 型（含 load / jalr） : imm[11:0]   = instr[31:20]
//     S 型                   : imm[11:0]   = {instr[31:25], instr[11:7]}
//     B 型                   : imm[12:1]   = {instr[31], instr[7], instr[30:25], instr[11:8]}
//     U 型（含 auipc）       : imm[31:12]  = instr[31:12]，低 12 位补 0
//     J 型                   : imm[20:1]   = {instr[31], instr[19:12], instr[20], instr[30:21]}
//   全部使用一热标志 + 按位与 + 或合并，便于综合到并行 LUT。
// =============================================================================
`include "../common/defines.sv"

module imm_gen #(
    parameter   DATAWIDTH = 32
)(
    input  logic [DATAWIDTH-1:0]   instr ,                  // 当前 ID 级指令
    output logic [DATAWIDTH-1:0]   imm                      // 符号扩展后的立即数
);
    // 从 instr 中先取 opcode，再判断指令格式
    logic [6:0] opcode;
    assign opcode = instr[6:0];

    // 按 RV32I 把指令分成 5 组立即数格式
    logic fmt_i, fmt_s, fmt_b, fmt_u, fmt_j;
    assign fmt_i = (opcode == `I_TYPE) || (opcode == `IL_TYPE) || (opcode == `IJ_TYPE);
    assign fmt_s = (opcode == `S_TYPE);
    assign fmt_b = (opcode == `B_TYPE);
    assign fmt_u = (opcode == `U_TYPE) || (opcode == `UA_TYPE);
    assign fmt_j = (opcode == `J_TYPE);

    // 按格式拼出符号扩展后的 32 位立即数；未命中位为 0
    assign imm = {32{fmt_i}} & {{20{instr[31]}}, instr[31:20]}                                       |
                 {32{fmt_s}} & {{20{instr[31]}}, instr[31:25], instr[11:7]}                          |
                 {32{fmt_b}} & {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0}          |
                 {32{fmt_u}} & {instr[31:12], 12'b0}                                                 |
                 {32{fmt_j}} & {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
endmodule
