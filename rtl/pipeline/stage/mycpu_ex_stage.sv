`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_ex_stage.sv —— EX（执行）级
//   - 在 alu 输入端实现 EX-EX / MEM-EX 双路前递（ForwardA/B 选择）
//   - 例化 alu 进行 RV32I 算术/逻辑/比较运算
//   - RV32M 指令交给独立多周期单元，EX 级等待完成后再向后推进
//   - 例化 csr_file 完成 csr_file 读写（包含 ecall/mret 重定向地址 csr_npc）
//   - 选择 npc_calc offset 来源（imm / jalr_target / csr_npc），并例化 npc_calc 算出
//     IF_npc_redirect、BranchTaken 与 BranchRedirect 反馈给前级
// =============================================================================
module mycpu_ex_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] MEM_forward_data ,       // 来自 MEM 级的前递候选
    input  logic [DATAWIDTH - 1:0] WB_wdata         ,       // 来自 WB 级的写回数据
    input  logic [DATAWIDTH - 1:0] EX_pc            ,
    input  logic [DATAWIDTH - 1:0] EX_imm           ,
    input  logic [DATAWIDTH - 1:0] EX_rR1_data      ,       // 寄存器堆原始读出
    input  logic [DATAWIDTH - 1:0] EX_rR2_data      ,
    input  logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl,
    input  logic [1:0]             EX_NpcOp         ,
    input  logic [1:0]             EX_OffsetOrigin  ,
    input  logic [11:0]            EX_csr_idx       ,
    input  logic [3:0]             EX_CSRControll   ,
    input  logic [1:0]             ForwardA         ,       // alu A 端前递选择
    input  logic [1:0]             ForwardB         ,       // alu B 端前递选择
    input  logic                   EX_ALUSrcA       ,
    input  logic                   EX_ALUSrcB       ,
    input  logic                   EX_pred_taken    ,
    input  logic [DATAWIDTH - 1:0] EX_pred_next_pc  ,
    input  logic                   clk              ,
    input  logic                   rst              ,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect  ,       // 给 IF 级的跳转目标
    output logic [DATAWIDTH - 1:0] EX_alu_result    ,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out ,       // B 端前递结果，给 EX/MEM
    output logic [DATAWIDTH - 1:0] EX_csr_wb        ,
    output logic                   BranchTaken      ,       // EX 级判跳成立
    output logic                   BranchRedirect   ,       // 预测错误或未预测跳转，需要修正前级
    output logic                   EX_busy                  // EX 多周期执行中
);
    logic [DATAWIDTH - 1:0] alu_in_a, alu_in_b;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] npc_offset;
    logic [DATAWIDTH - 1:0] jalr_target;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic [DATAWIDTH - 1:0] alu_result_i;
    logic [DATAWIDTH - 1:0] m_result;
    logic                   alu_isTrue;
    logic                   is_m_op;
    logic                   m_busy, m_done, m_start;
    logic                   EX_is_control;
    logic                   EX_actual_taken;
    logic                   EX_branch_mispredict;
    logic                   EX_jump_redirect;

    // 双路前递：根据 ForwardA/B 在 EX/MEM、MEM/WB、寄存器堆三者间选
    assign EX_forward_A_out = (ForwardA == 2'b10) ? MEM_forward_data :
                              (ForwardA == 2'b01) ? WB_wdata         :
                                                    EX_rR1_data      ;
    assign EX_forward_B_out = (ForwardB == 2'b10) ? MEM_forward_data :
                              (ForwardB == 2'b01) ? WB_wdata         :
                                                    EX_rR2_data      ;

    // alu 输入选择：A 端 pc/rs1，B 端 imm/rs2
    assign alu_in_a = EX_ALUSrcA ? EX_pc  : EX_forward_A_out;
    assign alu_in_b = EX_ALUSrcB ? EX_imm : EX_forward_B_out;
    assign is_m_op  = |EX_ALUControl[21:14];

    // RV32I 轻量 alu：只保留加减/逻辑/比较等短路径运算。
    alu #(DATAWIDTH) u_alu (
        .A          (alu_in_a       ),
        .B          (alu_in_b       ),
        .ALUControl (EX_ALUControl  ),
        .Result     (alu_result_i   ),
        .isTrue     (alu_isTrue     )
    );

    // start 只在该条 M 指令刚进入 EX 时打一拍。
    // done 会在结果提交后保持一拍，所以这里要额外屏蔽 !m_done，避免同一条指令重复启动。
    assign m_start = is_m_op && !m_busy && !m_done;

    rv32m_unit #(DATAWIDTH) u_rv32m_unit (
        .clk         (clk           ),
        .rst         (rst           ),
        .start       (m_start       ),
        .alu_control (EX_ALUControl ),
        .operand_a   (alu_in_a      ),
        .operand_b   (alu_in_b      ),
        .busy        (m_busy        ),
        .done        (m_done        ),
        .result      (m_result      )
    );

    assign EX_busy       = is_m_op && !m_done;
    assign EX_alu_result = is_m_op ? m_result : alu_result_i;

    // csr_file 模块：rs1 用前递后的 A 端数据
    csr_file #(DATAWIDTH) u_csr_file (
        .clk         (clk             ),
        .rst         (rst             ),
        .pc          (EX_pc           ),
        .rf1         (EX_forward_A_out),
        .csr_idx     (EX_csr_idx      ),
        .CSRControll (EX_CSRControll  ),
        .csr_npc     (csr_npc         ),
        .csr_wb      (EX_csr_wb       )
    );

    // JALR 目标地址单独旁路计算，避免把完整 alu 结果网络挂到 pc_reg 重定向时序上。
    assign jalr_target = (EX_forward_A_out + EX_imm) & {{DATAWIDTH - 1{1'b1}}, 1'b0};

    // npc_calc 偏移量来源选择：imm（branch/jal）/ jalr_target / csr_npc（ecall·mret）
    assign npc_offset = {DATAWIDTH{EX_OffsetOrigin == 2'b00}} & EX_imm        |
                        {DATAWIDTH{EX_OffsetOrigin == 2'b01}} & jalr_target   |
                        {DATAWIDTH{EX_OffsetOrigin == 2'b10}} & csr_npc       ;

    // 计算下一 pc_reg（仅用于跳转重定向，pcadd4 已在 EX/MEM 寄存器里单独算）
    npc_calc #(DATAWIDTH) u_npc_calc (
        .isTrue (alu_isTrue      ),
        .npc_op (EX_NpcOp        ),
        .pc     (EX_pc           ),
        .offset (npc_offset      ),
        .npc    (IF_npc_redirect ),
        .pcadd4 (                )
    );

    // 跳转判定：分支条件成立 / jalr·mret / jal
    assign EX_is_control   = (EX_NpcOp != 2'b00);
    assign EX_actual_taken = (EX_NpcOp == 2'b01 && alu_isTrue) ||
                             (EX_NpcOp == 2'b10              ) ||
                             (EX_NpcOp == 2'b11              );
    assign BranchTaken     = !EX_busy && EX_actual_taken;

    // IF 级已对条件分支做 BTFNT 预测；EX 级只在预测方向/目标不一致时冲刷修正。
    assign EX_branch_mispredict = (EX_NpcOp == 2'b01) &&
                                  ((alu_isTrue != EX_pred_taken) ||
                                   (IF_npc_redirect != EX_pred_next_pc));
    assign EX_jump_redirect     = (EX_NpcOp == 2'b10 || EX_NpcOp == 2'b11) &&
                                  (IF_npc_redirect != EX_pred_next_pc);
    assign BranchRedirect       = !EX_busy && EX_is_control &&
                                  (EX_branch_mispredict || EX_jump_redirect);
endmodule

module rv32m_unit #(
    parameter DATAWIDTH = 32,
    parameter DIV_LATENCY = 32
) (
    input  logic                     clk,
    input  logic                     rst,
    input  logic                     start,
    input  logic [`ALU_OP_WIDTH-1:0] alu_control,
    input  logic [DATAWIDTH-1:0]     operand_a,
    input  logic [DATAWIDTH-1:0]     operand_b,
    output logic                     busy,
    output logic                     done,
    output logic [DATAWIDTH-1:0]     result
);
    localparam OP_MUL    = 3'd0;
    localparam OP_MULH   = 3'd1;
    localparam OP_MULHSU = 3'd2;
    localparam OP_MULHU  = 3'd3;
    localparam OP_DIV    = 3'd4;
    localparam OP_DIVU   = 3'd5;
    localparam OP_REM    = 3'd6;
    localparam OP_REMU   = 3'd7;

    logic op_mul, op_mulh, op_mulhsu, op_mulhu, op_div, op_divu, op_rem, op_remu;
    logic busy_q, done_q;
    logic mode_mul_q, special_q;
    logic negate_mul_q, negate_quot_q, negate_rem_q;
    logic [2:0] op_sel_q;
    logic [5:0] cycles_left_q;
    logic [DATAWIDTH-1:0] result_q, special_result_q;
    logic [DATAWIDTH-1:0] abs_a, abs_b;
    logic [63:0] product_acc_q, multiplicand_q, product_next, product_signed;
    logic [31:0] multiplier_q;
    logic [32:0] remainder_q, rem_shift, rem_next;
    logic [31:0] quotient_q, quotient_next, quotient_final, divisor_q;
    logic        rem_ge_divisor;
    logic        signed_a, signed_b;
    logic        div_by_zero, div_overflow;
    logic [DATAWIDTH-1:0] quot_signed, rem_signed;

    assign op_mul    = alu_control[14];
    assign op_mulh   = alu_control[15];
    assign op_mulhsu = alu_control[16];
    assign op_mulhu  = alu_control[17];
    assign op_div    = alu_control[18];
    assign op_divu   = alu_control[19];
    assign op_rem    = alu_control[20];
    assign op_remu   = alu_control[21];

    assign div_by_zero  = (operand_b == '0);
    assign div_overflow = (operand_a == {1'b1, {(DATAWIDTH-1){1'b0}}}) &&
                          (operand_b == {DATAWIDTH{1'b1}});
    assign signed_a = op_mulh | op_mulhsu | op_div | op_rem;
    assign signed_b = op_mulh | op_div | op_rem;
    assign abs_a = (signed_a && operand_a[31]) ? (~operand_a + 1'b1) : operand_a;
    assign abs_b = (signed_b && operand_b[31]) ? (~operand_b + 1'b1) : operand_b;

    assign product_next   = product_acc_q + (multiplier_q[0] ? multiplicand_q : 64'd0);
    assign product_signed = negate_mul_q ? (~product_next + 64'd1) : product_next;
    assign rem_shift      = {remainder_q[31:0], quotient_q[31]};
    assign quotient_next  = {quotient_q[30:0], 1'b0};
    assign rem_ge_divisor = rem_shift >= {1'b0, divisor_q};
    assign quotient_final = quotient_next | {31'd0, rem_ge_divisor};
    assign rem_next       = rem_ge_divisor ? (rem_shift - {1'b0, divisor_q}) : rem_shift;
    assign quot_signed    = negate_quot_q ? (~quotient_final + 1'b1) : quotient_final;
    assign rem_signed     = negate_rem_q ? (~rem_next[31:0] + 1'b1) : rem_next[31:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            busy_q           <= 1'b0;
            done_q           <= 1'b0;
            mode_mul_q       <= 1'b0;
            special_q        <= 1'b0;
            negate_mul_q     <= 1'b0;
            negate_quot_q    <= 1'b0;
            negate_rem_q     <= 1'b0;
            op_sel_q         <= '0;
            cycles_left_q    <= '0;
            result_q         <= '0;
            special_result_q <= '0;
            product_acc_q    <= '0;
            multiplicand_q   <= '0;
            multiplier_q     <= '0;
            remainder_q      <= '0;
            quotient_q       <= '0;
            divisor_q        <= '0;
        end else if (start && !busy_q) begin
            done_q <= 1'b0;
            busy_q <= 1'b1;
            if (op_mul || op_mulh || op_mulhsu || op_mulhu) begin
                mode_mul_q     <= 1'b1;
                special_q      <= 1'b0;
                negate_mul_q   <= (op_mulh || op_mulhsu) && (operand_a[31] ^ (op_mulh && operand_b[31]));
                op_sel_q       <= op_mul ? OP_MUL :
                                  op_mulh ? OP_MULH :
                                  op_mulhsu ? OP_MULHSU : OP_MULHU;
                cycles_left_q  <= 6'd32;
                product_acc_q  <= 64'd0;
                multiplicand_q <= {32'd0, (op_mul ? operand_a : abs_a)};
                multiplier_q   <= op_mul ? operand_b : ((op_mulhsu || op_mulh || op_mulhu) ? abs_b : operand_b);
            end else begin
                mode_mul_q    <= 1'b0;
                op_sel_q      <= op_div ? OP_DIV :
                                 op_divu ? OP_DIVU :
                                 op_rem ? OP_REM : OP_REMU;
                negate_quot_q <= (op_div || op_rem) && (operand_a[31] ^ operand_b[31]);
                negate_rem_q  <= (op_div || op_rem) && operand_a[31];
                if (div_by_zero) begin
                    special_q        <= 1'b1;
                    cycles_left_q    <= 6'd1;
                    special_result_q <= (op_div || op_divu) ? {DATAWIDTH{1'b1}} : operand_a;
                end else if (div_overflow) begin
                    special_q        <= 1'b1;
                    cycles_left_q    <= 6'd1;
                    special_result_q <= op_div ? operand_a : '0;
                end else begin
                    special_q      <= 1'b0;
                    cycles_left_q  <= DIV_LATENCY[5:0];
                    remainder_q    <= '0;
                    quotient_q     <= (op_div || op_rem) ? abs_a : operand_a;
                    divisor_q      <= (op_div || op_rem) ? abs_b : operand_b;
                end
            end
        end else if (busy_q) begin
            if (special_q) begin
                busy_q    <= 1'b0;
                done_q    <= 1'b1;
                special_q <= 1'b0;
                result_q  <= special_result_q;
            end else if (mode_mul_q) begin
                if (cycles_left_q == 6'd1) begin
                    busy_q <= 1'b0;
                    done_q <= 1'b1;
                    case (op_sel_q)
                        OP_MUL:    result_q <= product_next[31:0];
                        OP_MULH:   result_q <= product_signed[63:32];
                        OP_MULHSU: result_q <= product_signed[63:32];
                        default:   result_q <= product_next[63:32];
                    endcase
                end else begin
                    cycles_left_q  <= cycles_left_q - 6'd1;
                    product_acc_q  <= product_next;
                    multiplicand_q <= multiplicand_q << 1;
                    multiplier_q   <= multiplier_q >> 1;
                end
            end else begin
                if (cycles_left_q == 6'd1) begin
                    busy_q <= 1'b0;
                    done_q <= 1'b1;
                    case (op_sel_q)
                        OP_DIV:  result_q <= quot_signed;
                        OP_DIVU: result_q <= quotient_final;
                        OP_REM:  result_q <= rem_signed;
                        default: result_q <= rem_next[31:0];
                    endcase
                end else begin
                    cycles_left_q <= cycles_left_q - 6'd1;
                    if (rem_ge_divisor) begin
                        remainder_q <= rem_shift - {1'b0, divisor_q};
                        quotient_q  <= quotient_final;
                    end else begin
                        remainder_q <= rem_shift;
                        quotient_q  <= quotient_next;
                    end
                end
            end
        end else if (done_q) begin
            done_q <= 1'b0;
        end
    end

    assign busy   = busy_q;
    assign done   = done_q;
    assign result = result_q;
endmodule
