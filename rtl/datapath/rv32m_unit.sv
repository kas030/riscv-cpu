`include "../common/defines.sv"

// =============================================================================
// rv32m_unit.sv
//   RV32M multiply/divide unit used by EX stage.
//   Multiplication keeps the current fast one-wait-cycle path; division and
//   remainder keep the 32-cycle iterative path.
// =============================================================================
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
    logic negate_quot_q, negate_rem_q;
    logic [2:0] op_sel_q;
    logic [5:0] cycles_left_q;
    logic [DATAWIDTH-1:0] result_q, special_result_q;
    logic [DATAWIDTH-1:0] abs_a, abs_b;
    logic [DATAWIDTH-1:0] mul_operand_a_q, mul_operand_b_q;
    logic [63:0] product_uu_fast;
    logic signed [63:0] product_ss_fast, product_su_fast;
    logic [31:0] product_hi_uu_q, product_hi_ss_q, product_hi_su_q;
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
            negate_quot_q    <= 1'b0;
            negate_rem_q     <= 1'b0;
            op_sel_q         <= '0;
            cycles_left_q    <= '0;
            result_q         <= '0;
            special_result_q <= '0;
            mul_operand_a_q  <= '0;
            mul_operand_b_q  <= '0;
            product_hi_uu_q  <= '0;
            product_hi_ss_q  <= '0;
            product_hi_su_q  <= '0;
            remainder_q      <= '0;
            quotient_q       <= '0;
            divisor_q        <= '0;
        end else if (start && !busy_q) begin
            done_q <= 1'b0;
            busy_q <= 1'b1;
            if (op_mul || op_mulh || op_mulhsu || op_mulhu) begin
                mode_mul_q      <= 1'b1;
                special_q       <= 1'b0;
                op_sel_q        <= op_mul ? OP_MUL :
                                   op_mulh ? OP_MULH :
                                   op_mulhsu ? OP_MULHSU : OP_MULHU;
                // 普通 MUL 仅取低 32 位，保持原延迟；三种高位乘法
                // 增加一级结果寄存，切断 DSP/符号修正长路径。
                cycles_left_q   <= op_mul ? 6'd1 : 6'd2;
                mul_operand_a_q <= operand_a;
                mul_operand_b_q <= operand_b;
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
                    special_q     <= 1'b0;
                    cycles_left_q <= DIV_LATENCY[5:0];
                    remainder_q   <= '0;
                    quotient_q    <= (op_div || op_rem) ? abs_a : operand_a;
                    divisor_q     <= (op_div || op_rem) ? abs_b : operand_b;
                end
            end
        end else if (busy_q) begin
            if (special_q) begin
                busy_q    <= 1'b0;
                done_q    <= 1'b1;
                special_q <= 1'b0;
                result_q  <= special_result_q;
            end else if (mode_mul_q) begin
                if (cycles_left_q == 6'd2) begin
                    product_hi_uu_q <= product_uu_fast[63:32];
                    product_hi_ss_q <= product_ss_fast[63:32];
                    product_hi_su_q <= product_su_fast[63:32];
                    cycles_left_q   <= 6'd1;
                end else if (cycles_left_q == 6'd1) begin
                    busy_q <= 1'b0;
                    done_q <= 1'b1;
                    case (op_sel_q)
                        OP_MUL:    result_q <= product_uu_fast[31:0];
                        OP_MULH:   result_q <= product_hi_ss_q;
                        OP_MULHSU: result_q <= product_hi_su_q;
                        default:   result_q <= product_hi_uu_q;
                    endcase
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
