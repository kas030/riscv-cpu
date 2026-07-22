// =============================================================================
// defines.sv —— RV32I/RV32M/Zbb 各类型指令 opcode 与公共宽度宏定义
//   被 main_ctrl / alu_ctrl / imm_gen 等译码模块通过 `include "defines.sv"` 引入，
//   宏值与 RISC-V 手册保持一致，调整时务必同步修改各使用处。
// =============================================================================
`ifndef DEFINES_SV
`define DEFINES_SV

//`define RUN_TRACE                       // 仿真追踪开关，默认关闭

// ---- RV32I opcode（指令最低 7 位）----
`define R_TYPE   7'b011_0011             // R 型：add/sub/and/or/xor/sll/srl/sra/...
`define I_TYPE   7'b001_0011             // I 型算术/逻辑：addi/andi/xori/...
`define IL_TYPE  7'b000_0011             // I 型 load：lb/lh/lw/lbu/lhu
`define IJ_TYPE  7'b110_0111             // I 型 jalr
`define S_TYPE   7'b010_0011             // S 型 store：sb/sh/sw
`define B_TYPE   7'b110_0011             // B 型 branch：beq/bne/blt/bge/bltu/bgeu
`define U_TYPE   7'b011_0111             // U 型 lui
`define UA_TYPE  7'b001_0111             // U 型 auipc
`define J_TYPE   7'b110_1111             // J 型 jal
`define CSR_TYPE 7'b111_0011             // csr_file / ecall / mret

`define OPCODE_LEN 7                     // opcode 字段宽度
`define ALU_OP_WIDTH 23                  // alu 独热操作码宽度

`endif
