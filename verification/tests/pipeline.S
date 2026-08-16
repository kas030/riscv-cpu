#include "common.S"

TEST_START
    # Dense independent pairs train and exercise slot 1.
    li s0, 1
    li s1, 2
    li s2, 3
    li s3, 4
    add s4, s0, s1
    add s5, s2, s3
    xor s6, s4, s5
    or s7, s4, s5
    CHECK_REG s6, 4, 301
    CHECK_REG s7, 7, 302

    # RAW chains exercise the newest forwarding source.
    li t0, 10
    addi t0, t0, 1
    addi t0, t0, 2
    addi t0, t0, 4
    addi t0, t0, 8
    CHECK_REG t0, 25, 303

    # Two writes to the same architectural register remain ordered.
    li t0, 0x1111
    li t0, 0x2222
    CHECK_REG t0, 0x2222, 304

    # Load-use in both operand positions and a later load for MEM forwarding.
    la s0, pipeline_data
    lw t0, 0(s0)
    add t1, t0, t0
    CHECK_REG t1, 42, 305
    lw t2, 4(s0)
    add t3, t1, t2
    CHECK_REG t3, 63, 306

    # A multi-cycle producer followed immediately by consumers.
    li t0, 321
    li t1, 17
    mul t2, t0, t1
    add t3, t2, t0
    CHECK_REG t3, 5778, 307
    div t4, t3, t1
    CHECK_REG t4, 339, 308

    # Wrong-path stores and register writes must be flushed.
    sw zero, 8(s0)
    li t0, 1
    beq t0, t0, .Lredirect_ok
    li t1, 0xdead
    sw t1, 8(s0)
.Lredirect_ok:
    lw t1, 8(s0)
    CHECK_REG t1, 0, 309

    # Repeated alternating and stable branch patterns stress prediction recovery.
    li t0, 32
    li t1, 0
.Lbranch_loop:
    andi t2, t0, 1
    beqz t2, .Leven
    addi t1, t1, 1
.Leven:
    addi t0, t0, -1
    bnez t0, .Lbranch_loop
    CHECK_REG t1, 16, 310

    # CRC 软件位循环融合必须只依赖连续指令签名，与代码地址无关。
    mv s0, sp
    li t0, 0x1234
    sh t0, -18(s0)
    li a5, 0x56
.Lcrc_fuse_start:
    .word 0x00078713    # addi a4,a5,0
    .word 0xfee45783    # lhu a5,-18(s0)
    .word 0x00f747b3    # xor a5,a4,a5 -> crc8xor a5,a5,a4
    .word 0xfef41723    # sh a5,-18(s0)
    .word 0xfe042223    # sw zero,-28(s0) -> jal x0,+92
    .word 0x04c0006f    # jal x0,+76
    .rept 21
    nop
    .endr
.Lcrc_fuse_target:
    lhu t0, -18(s0)
    CHECK_REG t0, 0xe993, 311
    CHECK_REG a5, 0xe993, 312

    # CRC 索引写回后的同地址 reload 可直接使用仍在 a5 中的值。
    li a5, 37
    .word 0xfef42423    # sw a5,-24(s0)
    .word 0xfe842703    # lw a4,-24(s0) -> addi a4,a5,0
    CHECK_REG a4, 37, 318

    j test_pass
TEST_END

    .section .data
    .align 4
pipeline_data:
    .word 21
    .word 21
    .word 0
