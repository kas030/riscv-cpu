#include "common.S"

TEST_START
    la s0, memory_data

    # Cold load, repeated load (L0 hit), and subword selection from cached word.
    lw t0, 0(s0)
    CHECK_REG t0, 0x80ff7f01, 401
    lw t0, 0(s0)
    CHECK_REG t0, 0x80ff7f01, 402
    lb t0, 3(s0)
    CHECK_REG t0, 0xffffff80, 403
    lhu t0, 2(s0)
    CHECK_REG t0, 0x80ff, 404

    # Store write-through and same-word L0 invalidation.
    li t0, 0x12
    sb t0, 2(s0)
    lw t1, 0(s0)
    CHECK_REG t1, 0x80127f01, 405
    li t0, 0xabcd
    sh t0, 0(s0)
    lw t1, 0(s0)
    CHECK_REG t1, 0x8012abcd, 406

    # Same cache index with a different tag must not return stale data.
    li t0, 0x80100100
    li t1, 0x11223344
    sw t1, 0(t0)
    lw t2, 0(s0)
    lw t3, 0(t0)
    CHECK_REG t2, 0x8012abcd, 407
    CHECK_REG t3, 0x11223344, 408

    # First and last naturally aligned BRAM words.
    li t0, 0x80100000
    li t1, 0x55667788
    sw t1, 0(t0)
    lw t2, 0(t0)
    CHECK_REG t2, 0x55667788, 409
    li t0, 0x8013fffc
    li t1, 0xa5a55a5a
    sw t1, 0(t0)
    lw t2, 0(t0)
    CHECK_REG t2, 0xa5a55a5a, 410
    li t1, 0x3c
    sb t1, 3(t0)
    lbu t2, 3(t0)
    CHECK_REG t2, 0x3c, 416

    # Defined MMIO accesses in the CPU-only zero-input environment.
    li t0, 0x80200000
    lw t1, 0(t0)
    CHECK_REG t1, 0, 411
    lw t1, 4(t0)
    CHECK_REG t1, 0, 412
    lw t1, 16(t0)
    CHECK_REG t1, 0, 413
    li t0, SEG_ADDR
    li t1, 0x12345678
    sw t1, 0(t0)
    lw t2, 0(t0)
    CHECK_REG t2, 0x12345678, 414

    # COUNTER only advances after the explicit start command.
    li t0, CNT_ADDR
    li t1, 0x80000000
    sw t1, 0(t0)
    li t2, 300000
.Lcounter_wait:
    addi t2, t2, -1
    bnez t2, .Lcounter_wait
    lw t3, 0(t0)
    FAIL_IF_ZERO t3, 415
    li t1, -1
    sw t1, 0(t0)

    j test_pass
TEST_END

    .section .data
    .align 4
memory_data:
    .word 0x80ff7f01
