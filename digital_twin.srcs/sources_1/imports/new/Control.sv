// =============================================================================
// Control.sv —— 主控制译码
//   位于 ID 级，根据 opcode + funct[2:0] 把指令分类成
//     R / I / IL / IJ / S / B / U / UA / J / CSR / call_ret 共 11 类，
//   再以一热标志合并产生 RegWrite / MemWrite / MemRead / MemToReg /
//   ALUSrcA / ALUSrcB / NpcOp / OffsetOrigin / isCSR 等控制信号，供后级使用。
// =============================================================================
`include "defines.sv"

module Control(
    input  logic [6:0]  opcode      ,                       // 指令最低 7 位
    input  logic [2:0]  funct       ,                       // funct3，用于区分 ecall/mret
    output logic [1:0]  NpcOp       ,                       // PC 重定向类型 → NPC 模块
    output logic        RegWrite    ,                       // 写回寄存器使能
    output logic [2:0]  MemToReg    ,                       // WB 级 5 路写回选择
    output logic        MemWrite    ,                       // DRAM/外设写使能
    output logic        MemRead     ,                       // load 标志，给 HazardUnit
    output logic [1:0]  OffsetOrigin,                       // EX 级 NPC 偏移量来源
    output logic        ALUSrcA     ,                       // ALU A 输入：rs1 / pc
    output logic        ALUSrcB     ,                       // ALU B 输入：rs2 / imm
    output logic        isCSR                               // CSR 类指令标志
);
    // 11 类指令独热标志
    logic is_jalr, is_branch, is_jal, is_store, is_rtype, is_itype;
    logic is_load, is_auipc, is_lui, is_csr, is_callret;

    assign is_jalr    =  (opcode == `IJ_TYPE);
    assign is_branch  =  (opcode == `B_TYPE);
    assign is_jal     =  (opcode == `J_TYPE);
    assign is_store   =  (opcode == `S_TYPE);
    assign is_rtype   =  (opcode == `R_TYPE);
    assign is_itype   =  (opcode == `I_TYPE);
    assign is_load    =  (opcode == `IL_TYPE);
    assign is_auipc   =  (opcode == `UA_TYPE);
    assign is_lui     =  (opcode == `U_TYPE);
    assign is_csr     =  (opcode == `CSR_TYPE) && (funct[2:0] != 3'b0);
    assign is_callret =  (opcode == `CSR_TYPE) && (funct[2:0] == 3'b0);

    // PC 重定向类型：00 顺序 / 01 分支 / 10 jalr·mret / 11 jal
    assign NpcOp        = {2{is_jalr   }} & 2'b10 |
                          {2{is_callret}} & 2'b10 |
                          {2{is_branch }} & 2'b01 |
                          {2{is_jal    }} & 2'b11;

    // branch / store / call·ret 不写回寄存器
    assign RegWrite     = ~(is_branch | is_store | is_callret);

    // WB 级写回数据来源（5 路独热）
    assign MemToReg     = {3{is_rtype}} & 3'b001 |
                          {3{is_itype}} & 3'b001 |
                          {3{is_auipc}} & 3'b001 |
                          {3{is_load }} & 3'b010 |
                          {3{is_lui  }} & 3'b011 |
                          {3{is_csr  }} & 3'b100;

    assign MemWrite     = is_store;                         // 仅 S 型写存储
    assign OffsetOrigin = {2{is_jalr   }} & 2'b01 |          // jalr：用 ALU 结果作目标
                          {2{is_callret}} & 2'b10;          // ecall/mret：用 csr_npc
    assign ALUSrcA      = is_auipc;                          // auipc 用 PC 作 A
    assign ALUSrcB      = ~(is_rtype | is_branch);           // 除 R 型/branch 外都用 imm
    assign MemRead      = is_load;                           // load 标志（HazardUnit 用）
    assign isCSR        = is_csr | is_callret;               // 通用 CSR 写回标志
endmodule
