`timescale 1ns / 1ps
// =============================================================================
// myCPU_ex_stage.sv —— EX（执行）级
//   - 在 ALU 输入端实现 EX-EX / MEM-EX 双路前递（ForwardA/B 选择）
//   - 例化 ALU 进行算术/逻辑/比较运算
//   - 例化 CSR 完成 CSR 读写（包含 ecall/mret 重定向地址 csr_npc）
//   - 选择 NPC offset 来源（imm / alu_result / csr_npc），并例化 NPC 算出
//     IF_npc_redirect 与 BranchTaken 反馈给 IF 级
// =============================================================================
module myCPU_ex_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] MEM_forward_data ,       // 来自 MEM 级的前递候选
    input  logic [DATAWIDTH - 1:0] WB_wdata         ,       // 来自 WB 级的写回数据
    input  logic [DATAWIDTH - 1:0] EX_pc            ,
    input  logic [DATAWIDTH - 1:0] EX_imm           ,
    input  logic [DATAWIDTH - 1:0] EX_rR1_data      ,       // 寄存器堆原始读出
    input  logic [DATAWIDTH - 1:0] EX_rR2_data      ,
    input  logic [13:0]            EX_ALUControl    ,
    input  logic [1:0]             EX_NpcOp         ,
    input  logic [1:0]             EX_OffsetOrigin  ,
    input  logic [11:0]            EX_csr_idx       ,
    input  logic [3:0]             EX_CSRControll   ,
    input  logic [1:0]             ForwardA         ,       // ALU A 端前递选择
    input  logic [1:0]             ForwardB         ,       // ALU B 端前递选择
    input  logic                   EX_ALUSrcA       ,
    input  logic                   EX_ALUSrcB       ,
    input  logic                   clk              ,
    input  logic                   rst              ,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect  ,       // 给 IF 级的跳转目标
    output logic [DATAWIDTH - 1:0] EX_alu_result    ,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out ,       // B 端前递结果，给 EX/MEM
    output logic [DATAWIDTH - 1:0] EX_csr_wb        ,
    output logic                   BranchTaken              // EX 级判跳成立
);
    logic [DATAWIDTH - 1:0] alu_in_a, alu_in_b;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] npc_offset;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic                   alu_isTrue;

    // 双路前递：根据 ForwardA/B 在 EX/MEM、MEM/WB、寄存器堆三者间选
    assign EX_forward_A_out = (ForwardA == 2'b10) ? MEM_forward_data :
                              (ForwardA == 2'b01) ? WB_wdata         :
                                                    EX_rR1_data      ;
    assign EX_forward_B_out = (ForwardB == 2'b10) ? MEM_forward_data :
                              (ForwardB == 2'b01) ? WB_wdata         :
                                                    EX_rR2_data      ;

    // ALU 输入选择：A 端 pc/rs1，B 端 imm/rs2
    assign alu_in_a = EX_ALUSrcA ? EX_pc  : EX_forward_A_out;
    assign alu_in_b = EX_ALUSrcB ? EX_imm : EX_forward_B_out;

    // 算术逻辑运算
    ALU #(DATAWIDTH) u_alu (
        .A          (alu_in_a       ),
        .B          (alu_in_b       ),
        .ALUControl (EX_ALUControl  ),
        .Result     (EX_alu_result  ),
        .isTrue     (alu_isTrue     )
    );

    // CSR 模块：rs1 用前递后的 A 端数据
    CSR #(DATAWIDTH) u_csr (
        .clk         (clk             ),
        .rst         (rst             ),
        .pc          (EX_pc           ),
        .rf1         (EX_forward_A_out),
        .csr_idx     (EX_csr_idx      ),
        .CSRControll (EX_CSRControll  ),
        .csr_npc     (csr_npc         ),
        .csr_wb      (EX_csr_wb       )
    );

    // NPC 偏移量来源选择：imm（branch/jal）/ alu_result（jalr）/ csr_npc（ecall·mret）
    assign npc_offset = {DATAWIDTH{EX_OffsetOrigin == 2'b00}} & EX_imm        |
                        {DATAWIDTH{EX_OffsetOrigin == 2'b01}} & EX_alu_result |
                        {DATAWIDTH{EX_OffsetOrigin == 2'b10}} & csr_npc       ;

    // 计算下一 PC（仅用于跳转重定向，pcadd4 已在 EX/MEM 寄存器里单独算）
    NPC #(DATAWIDTH) u_npc (
        .isTrue (alu_isTrue      ),
        .npc_op (EX_NpcOp        ),
        .pc     (EX_pc           ),
        .offset (npc_offset      ),
        .npc    (IF_npc_redirect ),
        .pcadd4 (                )
    );

    // 跳转判定：分支条件成立 / jalr·mret / jal
    assign BranchTaken = (EX_NpcOp == 2'b01 && alu_isTrue) ||
                         (EX_NpcOp == 2'b10              ) ||
                         (EX_NpcOp == 2'b11              );
endmodule
