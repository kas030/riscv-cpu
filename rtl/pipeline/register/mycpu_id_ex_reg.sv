`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_id_ex_reg.sv —— ID/EX 流水线寄存器
//   - 把 ID 级译出的所有数据通路与控制信号锁存到 EX 级
//   - rst 或 Flush_ID_EX（load-use 注气泡 / 跳转冲刷）时把所有控制信号清零，
//     等价于注入一条无副作用的空指令；数据通路同时清零，便于波形观察
// =============================================================================
module mycpu_id_ex_reg #(
    parameter DATAWIDTH  = 32  ,
    parameter ADDR_WIDTH = 5
) (
    // ---- 输入：来自 ID 级 ----
    input  logic [DATAWIDTH - 1:0]  ID_pc           ,
    input  logic [DATAWIDTH - 1:0]  ID_imm          ,
    input  logic [DATAWIDTH - 1:0]  ID_rR1_data     ,
    input  logic [DATAWIDTH - 1:0]  ID_rR2_data     ,
    input  logic [ADDR_WIDTH - 1:0] ID_rs1          ,
    input  logic [ADDR_WIDTH - 1:0] ID_rs2          ,
    input  logic [ADDR_WIDTH - 1:0] ID_rd           ,
    input  logic                    ID_RegWrite     ,
    input  logic                    ID_MemWrite     ,
    input  logic                    ID_MemRead      ,
    input  logic                    ID_isCSR        ,
    input  logic [2:0]              ID_MemToReg     ,
    input  logic [2:0]              ID_funct3       ,
    input  logic                    ID_ALUSrcA      ,
    input  logic                    ID_ALUSrcB      ,
    input  logic [`ALU_OP_WIDTH - 1:0] ID_ALUControl,
    input  logic [1:0]              ID_NpcOp        ,
    input  logic [1:0]              ID_OffsetOrigin ,
    input  logic [11:0]             ID_csr_idx      ,
    input  logic [4:0]              ID_csr_zimm     ,
    input  logic [5:0]              ID_CSRControll  ,
    input  logic                    ID_pred_taken   ,
    input  logic [DATAWIDTH - 1:0]  ID_pred_target  ,
    input  logic                    clk             ,
    input  logic                    rst             ,
    input  logic                    Flush_ID_EX     ,
    input  logic                    Stall_ID_EX     ,
    // ---- 输出：送往 EX 级 ----
    output logic [DATAWIDTH - 1:0]  EX_pc           ,
    output logic [DATAWIDTH - 1:0]  EX_imm          ,
    output logic [DATAWIDTH - 1:0]  EX_rR1_data     ,
    output logic [DATAWIDTH - 1:0]  EX_rR2_data     ,
    output logic [ADDR_WIDTH - 1:0] EX_rs1          ,
    output logic [ADDR_WIDTH - 1:0] EX_rs2          ,
    output logic [ADDR_WIDTH - 1:0] EX_rd           ,
    output logic                    EX_RegWrite     ,
    output logic                    EX_MemWrite     ,
    output logic                    EX_MemRead      ,
    output logic                    EX_isCSR        ,
    output logic [2:0]              EX_MemToReg     ,
    output logic [2:0]              EX_funct3       ,
    output logic                    EX_ALUSrcA      ,
    output logic                    EX_ALUSrcB      ,
    output logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl,
    output logic [1:0]              EX_NpcOp        ,
    output logic [1:0]              EX_OffsetOrigin ,
    output logic [11:0]             EX_csr_idx      ,
    output logic [4:0]              EX_csr_zimm     ,
    output logic [5:0]              EX_CSRControll  ,
    output logic                    EX_pred_taken   ,
    output logic [DATAWIDTH - 1:0]  EX_pred_target
);
    always_ff @(posedge clk) begin
        if (rst || Flush_ID_EX) begin
            // 复位 / 注气泡：所有控制信号清零，相当于一条无副作用的 NOP
            EX_RegWrite     <= 1'b0;
            EX_MemWrite     <= 1'b0;
            EX_MemRead      <= 1'b0;
            EX_isCSR        <= 1'b0;
            EX_ALUSrcA      <= 1'b0;
            EX_ALUSrcB      <= 1'b0;
            EX_MemToReg     <= '0;
            EX_funct3       <= '0;
            EX_ALUControl   <= '0;
            EX_NpcOp        <= '0;
            EX_OffsetOrigin <= '0;
            EX_CSRControll  <= '0;
            EX_pc           <= '0;
            EX_imm          <= '0;
            EX_rR1_data     <= '0;
            EX_rR2_data     <= '0;
            EX_rs1          <= '0;
            EX_rs2          <= '0;
            EX_rd           <= '0;
            EX_csr_idx      <= '0;
            EX_csr_zimm     <= '0;
            EX_pred_taken   <= 1'b0;
            EX_pred_target  <= '0;
        end else if (Stall_ID_EX) begin
            // EX 级多周期指令执行期间保持当前内容，等待结果就绪后再向后推进。
        end else begin
            // 正常推进：把 ID 级所有信号锁存进 EX 级
            EX_pc           <= ID_pc;
            EX_imm          <= ID_imm;
            EX_rR1_data     <= ID_rR1_data;
            EX_rR2_data     <= ID_rR2_data;
            EX_rs1          <= ID_rs1;
            EX_rs2          <= ID_rs2;
            EX_rd           <= ID_rd;
            EX_RegWrite     <= ID_RegWrite;
            EX_MemWrite     <= ID_MemWrite;
            EX_MemRead      <= ID_MemRead;
            EX_isCSR        <= ID_isCSR;
            EX_MemToReg     <= ID_MemToReg;
            EX_funct3       <= ID_funct3;
            EX_ALUSrcA      <= ID_ALUSrcA;
            EX_ALUSrcB      <= ID_ALUSrcB;
            EX_ALUControl   <= ID_ALUControl;
            EX_NpcOp        <= ID_NpcOp;
            EX_OffsetOrigin <= ID_OffsetOrigin;
            EX_csr_idx      <= ID_csr_idx;
            EX_csr_zimm     <= ID_csr_zimm;
            EX_CSRControll  <= ID_CSRControll;
            EX_pred_taken   <= ID_pred_taken;
            EX_pred_target  <= ID_pred_target;
        end
    end
endmodule
