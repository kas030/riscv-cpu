`timescale 1ns / 1ps

// CoreMark 计时专用单精度浮点协处理器。
// 支持 u32 -> binary32 与有限正规 binary32 除法；通过 MMIO 访问，
// 计算发生在 stop_time() 之后，不改变整数基准循环和 CPU 固定接口。
module fpu_mmio (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,
    input  logic        wen,
    output logic [31:0] rdata
);
    localparam logic [31:0] FPU_A_ADDR      = 32'h8020_0070;
    localparam logic [31:0] FPU_B_ADDR      = 32'h8020_0074;
    localparam logic [31:0] FPU_CMD_ADDR    = 32'h8020_0078;
    localparam logic [31:0] FPU_STATUS_ADDR = 32'h8020_007c;
    localparam logic [31:0] FPU_RESULT_ADDR = 32'h8020_0080;

    localparam logic [31:0] CMD_U32_TO_F32 = 32'd1;
    localparam logic [31:0] CMD_DIV_F32    = 32'd2;

    logic [31:0] operand_a_q, operand_b_q, result_q;
    logic        busy_q, done_q, sign_q, convert_q;
    logic [31:0] normalize_q;
    logic [7:0]  convert_exponent_q;
    logic [24:0] remainder_q;
    logic [23:0] divisor_q;
    logic [25:0] quotient_q;
    logic [4:0]  iteration_q;
    logic signed [9:0] exponent_q;

    logic [7:0]  a_exp, b_exp;
    logic [23:0] a_sig, b_sig;
    logic        sig_less;
    logic [24:0] initial_numerator;
    logic signed [9:0] initial_exponent;
    logic [24:0] shifted_remainder, next_remainder;
    logic [25:0] next_quotient;
    logic        quotient_bit;

    assign a_exp = operand_a_q[30:23];
    assign b_exp = operand_b_q[30:23];
    assign a_sig = {1'b1, operand_a_q[22:0]};
    assign b_sig = {1'b1, operand_b_q[22:0]};
    assign sig_less = a_sig < b_sig;
    assign initial_numerator = sig_less ? {a_sig, 1'b0}
                                        : {1'b0, a_sig};
    assign initial_exponent = $signed({2'b00, a_exp})
                            - $signed({2'b00, b_exp})
                            - (sig_less ? 10'sd1 : 10'sd0);

    assign shifted_remainder = remainder_q << 1;
    assign quotient_bit = shifted_remainder >= {1'b0, divisor_q};
    assign next_remainder = quotient_bit
                          ? shifted_remainder - {1'b0, divisor_q}
                          : shifted_remainder;

    always_comb begin
        next_quotient = quotient_q;
        next_quotient[24 - iteration_q] = quotient_bit;
    end

    // 输入已逐拍左移至最高位为 1；本函数只做舍入和打包，
    // 避免将 32 位优先编码器放在单拍时序路径上。
    function automatic [31:0] pack_normalized_u32(
        input logic [31:0] normalized,
        input logic [7:0] exponent
    );
        logic [24:0] rounded;
        logic [23:0] significand;
        logic [7:0] exponent_out;
        logic round_up;
        begin
            round_up = normalized[7]
                     && ((|normalized[6:0]) || normalized[8]);
            rounded = {1'b0, normalized[31:8]}
                    + {{24{1'b0}}, round_up};
            if (rounded[24]) begin
                significand = rounded[24:1];
                exponent_out = exponent + 8'd1;
            end else begin
                significand = rounded[23:0];
                exponent_out = exponent;
            end
            pack_normalized_u32 = {1'b0, exponent_out,
                                   significand[22:0]};
        end
    endfunction

    function automatic [31:0] round_and_pack(
        input logic [25:0] quotient,
        input logic [24:0] remainder,
        input logic signed [9:0] exponent,
        input logic sign
    );
        logic [24:0] rounded;
        logic [23:0] significand;
        logic round_up;
        logic signed [10:0] normalized_exponent;
        logic signed [10:0] biased_exponent;
        begin
            round_up = quotient[1]
                     && (quotient[0] || (remainder != 0) || quotient[2]);
            rounded = {1'b0, quotient[25:2]}
                    + {{24{1'b0}}, round_up};
            normalized_exponent = {exponent[9], exponent};
            if (rounded[24]) begin
                significand = rounded[24:1];
                normalized_exponent = normalized_exponent + 11'sd1;
            end else begin
                significand = rounded[23:0];
            end

            biased_exponent = normalized_exponent + 11'sd127;
            if (biased_exponent <= 0)
                round_and_pack = {sign, 31'd0};
            else if (biased_exponent >= 255)
                round_and_pack = {sign, 8'hff, 23'd0};
            else
                round_and_pack = {sign, biased_exponent[7:0],
                                  significand[22:0]};
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            operand_a_q <= 32'd0;
            operand_b_q <= 32'd0;
            result_q <= 32'd0;
            busy_q <= 1'b0;
            done_q <= 1'b0;
            sign_q <= 1'b0;
            convert_q <= 1'b0;
            normalize_q <= 32'd0;
            convert_exponent_q <= 8'd0;
            remainder_q <= 25'd0;
            divisor_q <= 24'd0;
            quotient_q <= 26'd0;
            iteration_q <= 5'd0;
            exponent_q <= 10'sd0;
        end else begin
            if (busy_q) begin
                if (convert_q) begin
                    if (normalize_q[31]) begin
                        result_q <= pack_normalized_u32(
                            normalize_q, convert_exponent_q);
                        busy_q <= 1'b0;
                        done_q <= 1'b1;
                    end else begin
                        normalize_q <= normalize_q << 1;
                        convert_exponent_q <= convert_exponent_q - 8'd1;
                    end
                end else begin
                    remainder_q <= next_remainder;
                    quotient_q <= next_quotient;
                    if (iteration_q == 5'd24) begin
                        result_q <= round_and_pack(next_quotient,
                                                   next_remainder,
                                                   exponent_q,
                                                   sign_q);
                        busy_q <= 1'b0;
                        done_q <= 1'b1;
                    end else begin
                        iteration_q <= iteration_q + 5'd1;
                    end
                end
            end

            if (wen) begin
                case (addr)
                    FPU_A_ADDR: operand_a_q <= wdata;
                    FPU_B_ADDR: operand_b_q <= wdata;
                    FPU_CMD_ADDR: begin
                        if (!busy_q) begin
                            done_q <= 1'b0;
                            if (wdata == CMD_U32_TO_F32) begin
                                if (operand_a_q == 0) begin
                                    result_q <= 32'd0;
                                    done_q <= 1'b1;
                                end else begin
                                    convert_q <= 1'b1;
                                    normalize_q <= operand_a_q;
                                    convert_exponent_q <= 8'd158;
                                    busy_q <= 1'b1;
                                end
                            end else if (wdata == CMD_DIV_F32) begin
                                if ((operand_b_q[30:23] == 0)
                                    && (operand_b_q[22:0] == 0)) begin
                                    result_q <= {operand_a_q[31] ^ operand_b_q[31],
                                                 8'hff, 23'd0};
                                    done_q <= 1'b1;
                                end else if ((operand_a_q[30:23] == 0)
                                             && (operand_a_q[22:0] == 0)) begin
                                    result_q <= {operand_a_q[31] ^ operand_b_q[31],
                                                 31'd0};
                                    done_q <= 1'b1;
                                end else if ((a_exp == 8'hff)
                                             || (b_exp == 8'hff)
                                             || (a_exp == 0)
                                             || (b_exp == 0)) begin
                                    result_q <= 32'h7fc0_0000;
                                    done_q <= 1'b1;
                                end else begin
                                    convert_q <= 1'b0;
                                    sign_q <= operand_a_q[31] ^ operand_b_q[31];
                                    exponent_q <= initial_exponent;
                                    divisor_q <= b_sig;
                                    remainder_q <= initial_numerator
                                                 - {1'b0, b_sig};
                                    quotient_q <= {1'b1, 25'd0};
                                    iteration_q <= 5'd0;
                                    busy_q <= 1'b1;
                                end
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    always_comb begin
        case (addr)
            FPU_A_ADDR:      rdata = operand_a_q;
            FPU_B_ADDR:      rdata = operand_b_q;
            FPU_STATUS_ADDR: rdata = {30'd0, done_q, busy_q};
            FPU_RESULT_ADDR: rdata = result_q;
            default:         rdata = 32'd0;
        endcase
    end
endmodule
