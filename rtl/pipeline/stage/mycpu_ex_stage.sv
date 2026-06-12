`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_ex_stage.sv —— EX（执行）级
//   - 在 alu 输入端实现 EX-EX / MEM-EX 双路前递（ForwardA/B 选择）
//   - 例化 alu 进行 RV32I 算术/逻辑/比较运算
//   - RV32M 指令交给独立多周期单元，EX 级等待完成后再向后推进
//   - 例化 csr_file 完成 csr_file 读写（包含 ecall/mret 重定向地址 csr_npc）
//   - 选择 npc_calc offset 来源（imm / jalr_target / csr_npc），并例化 npc_calc 算出
//     raw redirect target、BranchTaken 和 BranchMispredict 反馈给前级打拍提交
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
    input  logic [4:0]             EX_csr_zimm      ,
    input  logic [5:0]             EX_CSRControll   ,
    input  logic [1:0]             ForwardA         ,       // alu A 端前递选择
    input  logic [1:0]             ForwardB         ,       // alu B 端前递选择
    input  logic                   EX_ALUSrcA       ,
    input  logic                   EX_ALUSrcB       ,
    input  logic                   EX_pred_taken    ,
    input  logic                   EX_stall         ,
    input  logic                   EX_kill          ,
    input  logic                   clk              ,
    input  logic                   rst              ,
    output logic [DATAWIDTH - 1:0] IF_npc_redirect_raw,     // EX 级算出的原始跳转目标
    output logic [DATAWIDTH - 1:0] EX_alu_result    ,
    output logic [DATAWIDTH - 1:0] EX_forward_B_out ,       // B 端前递结果，给 EX/MEM
    output logic [DATAWIDTH - 1:0] EX_csr_wb        ,
    output logic                   BranchTaken      ,       // EX 级判跳成立
    output logic                   BranchMispredict ,
    output logic                   EX_busy                  // EX 多周期执行中
);
    logic [DATAWIDTH - 1:0] alu_in_a, alu_in_b;
    logic [DATAWIDTH - 1:0] EX_forward_A_out;
    logic [DATAWIDTH - 1:0] EX_forward_A_comb, EX_forward_B_comb;
    logic [DATAWIDTH - 1:0] EX_forward_A_hold, EX_forward_B_hold;
    logic                   EX_forward_hold_valid;
    logic [DATAWIDTH - 1:0] npc_offset;
    logic [DATAWIDTH - 1:0] jalr_target;
    logic [DATAWIDTH - 1:0] csr_npc;
    logic [DATAWIDTH - 1:0] csr_wdata;
    logic [5:0]             csr_control_effective;
    logic [DATAWIDTH - 1:0] alu_result_i;
    logic [DATAWIDTH - 1:0] m_result;
    logic                   alu_isTrue;
    logic                   is_m_op;
    logic                   is_control_flow;
    logic                   control_taken;
    logic                   m_busy, m_done, m_start;

    // 双路前递：根据 ForwardA/B 在 EX/MEM、MEM/WB、寄存器堆三者间选
    assign EX_forward_A_comb = (ForwardA == 2'b10) ? MEM_forward_data :
                               (ForwardA == 2'b01) ? WB_wdata         :
                                                     EX_rR1_data      ;
    assign EX_forward_B_comb = (ForwardB == 2'b10) ? MEM_forward_data :
                               (ForwardB == 2'b01) ? WB_wdata         :
                                                     EX_rR2_data      ;

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
    assign m_start = !EX_kill && is_m_op && !m_busy && !m_done;

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

    assign EX_busy       = !EX_kill && is_m_op && !m_done;
    assign EX_alu_result = is_m_op ? m_result : alu_result_i;
    assign csr_wdata     = EX_CSRControll[5] ? {{(DATAWIDTH-5){1'b0}}, EX_csr_zimm} :
                                               EX_forward_A_out;
    assign csr_control_effective = EX_kill ? 6'b0 : EX_CSRControll;

    // csr_file 模块：rs1 用前递后的 A 端数据
    csr_file #(DATAWIDTH) u_csr_file (
        .clk         (clk             ),
        .rst         (rst             ),
        .pc          (EX_pc           ),
        .csr_wdata   (csr_wdata       ),
        .csr_idx     (EX_csr_idx      ),
        .CSRControll (csr_control_effective),
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
        .npc    (IF_npc_redirect_raw),
        .pcadd4 (                )
    );

    // 跳转判定：分支条件成立 / jalr·mret / jal
    assign control_taken = (EX_NpcOp == 2'b01 && alu_isTrue) ||
                           (EX_NpcOp == 2'b10              ) ||
                           (EX_NpcOp == 2'b11              );

    assign BranchTaken = !EX_kill && !EX_busy && control_taken;

    assign is_control_flow  = (EX_NpcOp != 2'b00);
    assign BranchMispredict = !EX_kill && !EX_busy && is_control_flow &&
                              (control_taken != EX_pred_taken);
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
    logic [DATAWIDTH-1:0] mul_operand_a_q, mul_operand_b_q;
    logic [63:0] product_acc_q, multiplicand_q, product_next, product_signed;
    logic [63:0] product_uu_fast;
    logic signed [63:0] product_ss_fast, product_su_fast;
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
    assign product_uu_fast = {32'd0, mul_operand_a_q} * {32'd0, mul_operand_b_q};
    assign product_ss_fast = $signed({{32{mul_operand_a_q[31]}}, mul_operand_a_q}) *
                             $signed({{32{mul_operand_b_q[31]}}, mul_operand_b_q});
    assign product_su_fast = $signed({{32{mul_operand_a_q[31]}}, mul_operand_a_q}) *
                             $signed({32'd0, mul_operand_b_q});
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
            mul_operand_a_q  <= '0;
            mul_operand_b_q  <= '0;
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
                cycles_left_q  <= 6'd1;
                mul_operand_a_q <= operand_a;
                mul_operand_b_q <= operand_b;
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
                        OP_MUL:    result_q <= product_uu_fast[31:0];
                        OP_MULH:   result_q <= product_ss_fast[63:32];
                        OP_MULHSU: result_q <= product_su_fast[63:32];
                        default:   result_q <= product_uu_fast[63:32];
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
