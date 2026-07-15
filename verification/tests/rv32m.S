#include "common.S"

TEST_START
    li t1, 0x80000003
    li t2, 7
    mul t0, t1, t2
    CHECK_REG t0, 0x80000015, 101

    li t1, -2
    li t2, 3
    mulh t0, t1, t2
    CHECK_REG t0, -1, 102
    mulhsu t0, t1, t2
    CHECK_REG t0, -1, 103
    li t1, -1
    li t2, -1
    mulhu t0, t1, t2
    CHECK_REG t0, 0xfffffffe, 104

    li t1, -20
    li t2, 6
    div t0, t1, t2
    CHECK_REG t0, -3, 105
    rem t0, t1, t2
    CHECK_REG t0, -2, 106
    li t1, 0xfffffff0
    divu t0, t1, t2
    CHECK_REG t0, 0x2aaaaaa8, 107
    remu t0, t1, t2
    CHECK_REG t0, 0, 108

    # Architectural special cases.
    li t1, 0x12345678
    div t0, t1, zero
    CHECK_REG t0, -1, 109
    divu t0, t1, zero
    CHECK_REG t0, -1, 110
    rem t0, t1, zero
    CHECK_REG t0, 0x12345678, 111
    remu t0, t1, zero
    CHECK_REG t0, 0x12345678, 112

    li t1, 0x80000000
    li t2, -1
    div t0, t1, t2
    CHECK_REG t0, 0x80000000, 113
    rem t0, t1, t2
    CHECK_REG t0, 0, 114

    # Unsigned operands with the same bit pattern are not signed overflow.
    li t1, 0x80000000
    li t2, 0xffffffff
    divu t0, t1, t2
    CHECK_REG t0, 0, 117
    remu t0, t1, t2
    CHECK_REG t0, 0x80000000, 118

    # Dependent operations exercise hold/release and forwarding.
    li t1, 12345
    li t2, 67
    mul t0, t1, t2
    addi t0, t0, 5
    CHECK_REG t0, 827120, 115
    div t3, t0, t2
    CHECK_REG t3, 12345, 116

    j test_pass
TEST_END
