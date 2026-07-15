#include "common.S"

TEST_START
    # U-type and immediate arithmetic.
    lui t0, 0x12345
    CHECK_REG t0, 0x12345000, 1
.Lauipc:
    auipc t0, 0
    la t1, .Lauipc
    CHECK_EQ t0, t1, 2

    li t0, 0x7fffffff
    addi t0, t0, 1
    CHECK_REG t0, 0x80000000, 3
    slti t0, t0, 0
    CHECK_REG t0, 1, 4
    li t1, -1
    sltiu t0, t1, 1
    CHECK_REG t0, 0, 5
    xori t0, t1, 0x55
    CHECK_REG t0, 0xffffffaa, 6
    ori t0, zero, 0x155
    CHECK_REG t0, 0x155, 7
    andi t0, t1, 0x5a5
    CHECK_REG t0, 0x000005a5, 8
    li t1, 1
    slli t0, t1, 31
    CHECK_REG t0, 0x80000000, 9
    srli t0, t0, 31
    CHECK_REG t0, 1, 10
    li t1, 0x80000000
    srai t0, t1, 31
    CHECK_REG t0, -1, 11

    # Register-register arithmetic and shifts.
    li t1, 0x7fffffff
    li t2, 1
    add t0, t1, t2
    CHECK_REG t0, 0x80000000, 12
    sub t0, zero, t2
    CHECK_REG t0, -1, 13
    li t2, 36
    li t1, 1
    sll t0, t1, t2
    CHECK_REG t0, 16, 14
    li t1, -2
    li t2, 1
    slt t0, t1, t2
    CHECK_REG t0, 1, 15
    sltu t0, t1, t2
    CHECK_REG t0, 0, 16
    li t1, 0x55aa55aa
    li t2, 0x0f0ff0f0
    xor t0, t1, t2
    CHECK_REG t0, 0x5aa5a55a, 17
    or t0, t1, t2
    CHECK_REG t0, 0x5faff5fa, 18
    and t0, t1, t2
    CHECK_REG t0, 0x050a50a0, 19
    li t1, 0x80000000
    li t2, 4
    srl t0, t1, t2
    CHECK_REG t0, 0x08000000, 20
    sra t0, t1, t2
    CHECK_REG t0, 0xf8000000, 21

    # x0 is immutable.
    li zero, -1
    CHECK_REG zero, 0, 22

    # All six branch operations, both directions where meaningful.
    li t0, -1
    li t1, 1
    beq t0, t1, test_fail
    bne t0, t1, .Lbne_ok
    j test_fail
.Lbne_ok:
    blt t0, t1, .Lblt_ok
    j test_fail
.Lblt_ok:
    bge t1, t0, .Lbge_ok
    j test_fail
.Lbge_ok:
    bltu t1, t0, .Lbltu_ok
    j test_fail
.Lbltu_ok:
    bgeu t0, t1, .Lbgeu_ok
    j test_fail
.Lbgeu_ok:
    beq t0, t0, .Lbeq_ok
    j test_fail
.Lbeq_ok:

    # jal writes PC+4; jalr clears target bit zero.
    jal ra, .Ljal_target
.Ljal_link:
    j test_fail
.Ljal_target:
    la t1, .Ljal_link
    CHECK_EQ ra, t1, 23
    la t0, .Ljalr_target
    ori t0, t0, 1
    jalr ra, 0(t0)
.Ljalr_link:
    j test_fail
.Ljalr_target:
    la t1, .Ljalr_link
    CHECK_EQ ra, t1, 24

    # All aligned load/store widths and byte lanes.
    la s0, rv32i_data
    lw t0, 0(s0)
    CHECK_REG t0, 0x80ff7f01, 25
    lb t0, 0(s0)
    CHECK_REG t0, 1, 26
    lb t0, 2(s0)
    CHECK_REG t0, -1, 27
    lbu t0, 3(s0)
    CHECK_REG t0, 0x80, 28
    lh t0, 0(s0)
    CHECK_REG t0, 0x7f01, 29
    lh t0, 2(s0)
    CHECK_REG t0, 0xffff80ff, 30
    lhu t0, 2(s0)
    CHECK_REG t0, 0x80ff, 31

    li t0, 0x11223344
    sw t0, 4(s0)
    li t0, 0xaa
    sb t0, 5(s0)
    li t0, 0xbbcc
    sh t0, 6(s0)
    lw t0, 4(s0)
    CHECK_REG t0, 0xbbccaa44, 32

    j test_pass
TEST_END

    .section .data
    .align 4
rv32i_data:
    .word 0x80ff7f01
    .word 0x00000000
