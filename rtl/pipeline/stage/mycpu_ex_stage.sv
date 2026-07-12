`timescale 1ns / 1ps
`include "../../common/defines.sv"

// =============================================================================
// mycpu_ex_stage.sv —— EX（执行）级
//   - 在 alu 输入端实现 EX-EX / MEM-EX 双路前递（ForwardA/B 选择）
//   - RV32M 指令交给独立多周期单元，EX 级等待完成后再向后推进
//   - 例化 csr_file 完成 CSR 读写，并在冲刷时屏蔽控制副作用
//   - 计算 raw redirect target、BranchTaken 和 BranchMispredict 反馈给前级打拍提交
// =============================================================================
module mycpu_ex_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] MEM_forward_data,
    input  logic [DATAWIDTH - 1:0] MEM_S1_forward_data,
    input  logic [DATAWIDTH - 1:0] MEM2_forward_data,
    input  logic [DATAWIDTH - 1:0] MEM2_S1_forward_data,
    input  logic [DATAWIDTH - 1:0] WB_wdata,
    input  logic [DATAWIDTH - 1:0] WB_S1_wdata,
    input  logic [DATAWIDTH - 1:0] EX_pc,
    input  logic [DATAWIDTH - 1:0] EX_imm,
    input  logic [DATAWIDTH - 1:0] EX_rR1_data,
    input  logic [DATAWIDTH - 1:0] EX_rR2_data,
    input  logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl,
    input  logic [1:0]             EX_NpcOp,
    input  logic [1:0]             EX_OffsetOrigin,
    input  logic [11:0]            EX_csr_idx,
    input  logic [4:0]             EX_csr_zimm,
    input  logic [5:0]             EX_CSRControll,
    input  logic [2:0]             ForwardA,
    input  logic [2:0]             ForwardB,
    input  logic                   EX_ALUSrcA,
    input  logic                   EX_ALUSrcB,
    input  logic                   EX_pred_taken,
    input  logic [DATAWIDTH - 1:0] EX_pred_target,
    input  logic                   EX_stall,
    input  logic                   EX_kill,
    input  logic                   clk,
    input  logic                   rst,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect_raw,
    output logic [DATAWIDTH - 1:0] EX_alu_result,
    output logic [DATAWIDTH - 1:0] EX_mem_addr,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out,
    output logic [DATAWIDTH - 1:0] EX_csr_wb,
    output logic                   BranchTaken,
    output logic                   BranchMispredict,
    output logic                   EX_busy
);
    logic [DATAWIDTH - 1:0] alu_in_a, alu_in_b;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] EX_forward_A_comb, EX_forward_B_comb;
    logic [DATAWIDTH - 1:0] EX_forward_A_hold, EX_forward_B_hold;
    logic                   EX_forward_hold_valid;
    logic [DATAWIDTH - 1:0] seq_pc;
    logic [DATAWIDTH - 1:0] branch_target;
    logic [DATAWIDTH - 1:0] jal_target;
    logic [DATAWIDTH - 1:0] jalr_target;
    logic [DATAWIDTH - 1:0] csr_target;
    logic [DATAWIDTH - 1:0] jalr_csr_target;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic [DATAWIDTH - 1:0] csr_wdata;
    logic [5:0]             csr_control_effective;
    logic [DATAWIDTH - 1:0] alu_result_i;
    logic [DATAWIDTH - 1:0] m_result;
    logic                   alu_isTrue;
    logic                   is_m_op;
    logic                   m_busy, m_done, m_start;
    logic                   branch_taken_raw;
    logic                   branch_mispredict_raw;

    always_comb begin
        unique case (ForwardA)
            3'd1:    EX_forward_A_comb = WB_wdata;
            3'd2:    EX_forward_A_comb = MEM_forward_data;
            3'd3:    EX_forward_A_comb = MEM2_forward_data;
            3'd4:    EX_forward_A_comb = WB_S1_wdata;
            3'd5:    EX_forward_A_comb = MEM_S1_forward_data;
            3'd6:    EX_forward_A_comb = MEM2_S1_forward_data;
            default: EX_forward_A_comb = EX_rR1_data;
        endcase
    end

    always_comb begin
        unique case (ForwardB)
            3'd1:    EX_forward_B_comb = WB_wdata;
            3'd2:    EX_forward_B_comb = MEM_forward_data;
            3'd3:    EX_forward_B_comb = MEM2_forward_data;
            3'd4:    EX_forward_B_comb = WB_S1_wdata;
            3'd5:    EX_forward_B_comb = MEM_S1_forward_data;
            3'd6:    EX_forward_B_comb = MEM2_S1_forward_data;
            default: EX_forward_B_comb = EX_rR2_data;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst || !EX_stall) begin
            EX_forward_hold_valid <= 1'b0;
        end else if (!EX_forward_hold_valid) begin
            EX_forward_A_hold     <= EX_forward_A_comb;
            EX_forward_B_hold     <= EX_forward_B_comb;
            EX_forward_hold_valid <= 1'b1;
        end
    end

    assign EX_forward_A_out = EX_forward_hold_valid ? EX_forward_A_hold : EX_forward_A_comb;
    assign EX_forward_B_out = EX_forward_hold_valid ? EX_forward_B_hold : EX_forward_B_comb;

    assign alu_in_a = EX_ALUSrcA ? EX_pc  : EX_forward_A_out;
    assign alu_in_b = EX_ALUSrcB ? EX_imm : EX_forward_B_out;
    assign is_m_op  = |EX_ALUControl[21:14];

    alu #(DATAWIDTH) u_alu (
        .A          (alu_in_a     ),
        .B          (alu_in_b     ),
        .ALUControl (EX_ALUControl),
        .Result     (alu_result_i ),
        .isTrue     (alu_isTrue   )
    );

    // start 只在该条 M 指令刚进入 EX 时打一拍。
    assign m_start = !EX_kill && is_m_op && !m_busy && !m_done;

    rv32m_unit #(DATAWIDTH) u_rv32m_unit (
        .clk         (clk          ),
        .rst         (rst          ),
        .start       (m_start      ),
        .alu_control (EX_ALUControl),
        .operand_a   (alu_in_a     ),
        .operand_b   (alu_in_b     ),
        .busy        (m_busy       ),
        .done        (m_done       ),
        .result      (m_result     )
    );

    assign EX_busy       = !EX_kill && is_m_op && !m_done;
    assign EX_alu_result = is_m_op ? m_result : alu_result_i;
    // load/store 只需要 base+imm，独立加法器避免访存地址穿过通用 ALU
    // 的移位/逻辑/比较结果汇总网络。
    assign EX_mem_addr   = EX_forward_A_out + EX_imm;
    assign csr_wdata     = EX_CSRControll[5] ? {{(DATAWIDTH-5){1'b0}}, EX_csr_zimm} :
                                               EX_forward_A_out;
    assign csr_control_effective = EX_kill ? 6'b0 : EX_CSRControll;

    csr_file #(DATAWIDTH) u_csr_file (
        .clk         (clk                  ),
        .rst         (rst                  ),
        .pc          (EX_pc                ),
        .csr_wdata   (csr_wdata            ),
        .csr_idx     (EX_csr_idx           ),
        .CSRControll (csr_control_effective),
        .csr_npc     (csr_npc              ),
        .csr_wb      (EX_csr_wb            )
    );

    assign seq_pc          = EX_pc + 4;
    assign branch_target   = EX_pc + EX_imm;
    assign jal_target      = branch_target;
    assign jalr_target     = (EX_forward_A_out + EX_imm) & {{DATAWIDTH - 1{1'b1}}, 1'b0};
    assign csr_target      = csr_npc;
    assign jalr_csr_target = (EX_OffsetOrigin == 2'b10) ? csr_target : jalr_target;

    assign IF_npc_redirect_raw = (EX_NpcOp == 2'b01) ? (alu_isTrue ? branch_target : seq_pc) :
                                 (EX_NpcOp == 2'b10) ? jalr_csr_target                    :
                                 (EX_NpcOp == 2'b11) ? jal_target                         :
                                                        seq_pc;

    mycpu_redirect_ctrl #(DATAWIDTH) u_redirect_ctrl (
        .ex_busy_i           (EX_busy            ),
        .ex_npc_op_i         (EX_NpcOp           ),
        .alu_branch_true_i   (alu_isTrue         ),
        .branch_target_i     (branch_target      ),
        .jal_target_i        (jal_target         ),
        .jalr_csr_target_i   (jalr_csr_target    ),
        .pred_taken_i        (EX_pred_taken      ),
        .pred_target_i       (EX_pred_target     ),
        .branch_taken_o      (branch_taken_raw   ),
        .branch_mispredict_o (branch_mispredict_raw)
    );

    assign BranchTaken      = EX_kill ? 1'b0 : branch_taken_raw;
    assign BranchMispredict = EX_kill ? 1'b0 : branch_mispredict_raw;
endmodule
