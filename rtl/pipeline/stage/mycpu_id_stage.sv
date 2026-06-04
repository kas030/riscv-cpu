`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_id_stage.sv —— ID（译码）级
//   - 抽取 instr 中的 rs1/rs2/rd/funct3 等寄存器号
//   - 例化 main_ctrl / imm_gen / alu_ctrl / csr_ctrl_decode，在同一拍内并行算出所有控制信号、
//     立即数、alu 操作码以及 csr_file 控制
//   - 寄存器堆 reg_file 在 mycpu.sv 顶层例化（不在本 stage 内部），原因是它需要
//     接收 WB 级的写口同时给 ID 提供读口，逻辑上跨级
// =============================================================================
module mycpu_id_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] ID_instr         ,       // 当前 ID 级指令
    output logic [DATAWIDTH - 1:0] ID_imm           ,       // 立即数
    output logic                   ID_RegWrite      ,       // 控制信号（详见 main_ctrl）
    output logic                   ID_MemWrite      ,
    output logic                   ID_MemRead       ,
    output logic                   ID_isCSR         ,
    output logic                   ID_ALUSrcA       ,
    output logic                   ID_ALUSrcB       ,
    output logic [2:0]             ID_MemToReg      ,
    output logic [1:0]             ID_NpcOp         ,
    output logic [1:0]             ID_OffsetOrigin  ,
    output logic [`ALU_OP_WIDTH - 1:0] ID_ALUControl,
    output logic [11:0]            ID_csr_idx       ,
    output logic [4:0]             ID_csr_zimm      ,
    output logic [5:0]             ID_CSRControll   ,
    output logic [2:0]             ID_funct3        ,
    output logic [4:0]             ID_rs1           ,
    output logic [4:0]             ID_rs2           ,
    output logic [4:0]             ID_rd
);
    // 直接从指令中切出寄存器号字段
    assign ID_rs1    = ID_instr[19:15];
    assign ID_rs2    = ID_instr[24:20];
    assign ID_rd     = ID_instr[11: 7];
    assign ID_funct3 = ID_instr[14:12];

    // 主控制译码 → 各种控制信号
    main_ctrl u_main_ctrl (
        .instr        (ID_instr       ),
        .opcode       (ID_instr[6:0]   ),
        .funct        (ID_funct3       ),
        .NpcOp        (ID_NpcOp        ),
        .RegWrite     (ID_RegWrite     ),
        .MemToReg     (ID_MemToReg     ),
        .MemWrite     (ID_MemWrite     ),
        .MemRead      (ID_MemRead      ),
        .OffsetOrigin (ID_OffsetOrigin ),
        .ALUSrcA      (ID_ALUSrcA      ),
        .ALUSrcB      (ID_ALUSrcB      ),
        .isCSR        (ID_isCSR        )
    );

    // 立即数生成
    imm_gen #(DATAWIDTH) u_imm_gen (
        .instr (ID_instr),
        .imm   (ID_imm  )
    );

    // alu 操作码译码（独热编码）
    alu_ctrl u_alu_ctrl (
        .opcode     (ID_instr[6:0]              ),
        .funct      ({ID_instr[31:25], ID_funct3}),
        .ALUControl (ID_ALUControl              )
    );

    // csr_file 控制译码
    csr_ctrl_decode u_csr_ctrl_decode (
        .instr       (ID_instr      ),
        .csr_idx     (ID_csr_idx    ),
        .csr_zimm    (ID_csr_zimm   ),
        .CSRControll (ID_CSRControll)
    );
endmodule
