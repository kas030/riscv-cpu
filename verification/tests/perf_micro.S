#include "common.S"

TEST_START
    # Deterministic mixed workload. Its counters are reported, never gated.
    la s0, perf_data
    li s1, 2000
    li s2, 1
    li s3, 3
.Lperf_loop:
    add s4, s2, s3
    xor s5, s2, s3
    addi s2, s2, 1
    addi s3, s3, 2
    lw s6, 0(s0)
    add s6, s6, s4
    sw s6, 0(s0)
    andi s7, s1, 7
    bnez s7, .Lskip_mul
    mul s8, s2, s3
.Lskip_mul:
    addi s1, s1, -1
    bnez s1, .Lperf_loop

    CHECK_REG s2, 2001, 501
    CHECK_REG s3, 4003, 502
    lw t0, 0(s0)
    FAIL_IF_ZERO t0, 503
    j test_pass
TEST_END

    .section .data
    .align 4
perf_data:
    .word 1
