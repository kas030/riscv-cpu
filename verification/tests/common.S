#ifndef VERIFICATION_COMMON_S
#define VERIFICATION_COMMON_S

    .option norvc
    .option norelax

    .equ LED_ADDR,  0x80200040
    .equ SEG_ADDR,  0x80200020
    .equ CNT_ADDR,  0x80200050
    .equ PASS_VALUE, 0xC0DEC0DE
    .equ FAIL_VALUE, 0xDEADBEEF

    .macro TEST_START
    .section .text.init
    .globl _start
_start:
    li sp, 0x8013fff0
    j test_main
    .section .text
test_main:
    .endm

    .macro CHECK_REG reg, expected, id
    li t6, \expected
    beq \reg, t6, .Lcheck_ok_\@
    la t5, test_signature
    li t4, \id
    sw t4, 0(t5)
    sw \reg, 4(t5)
    sw t6, 8(t5)
    j test_fail
.Lcheck_ok_\@:
    .endm

    .macro CHECK_EQ lhs, rhs, id
    beq \lhs, \rhs, .Lcheck_eq_ok_\@
    la t5, test_signature
    li t4, \id
    sw t4, 0(t5)
    sw \lhs, 4(t5)
    sw \rhs, 8(t5)
    j test_fail
.Lcheck_eq_ok_\@:
    .endm

    .macro FAIL_IF_ZERO reg, id
    bnez \reg, .Lnonzero_ok_\@
    la t5, test_signature
    li t4, \id
    sw t4, 0(t5)
    sw zero, 4(t5)
    li t6, 1
    sw t6, 8(t5)
    j test_fail
.Lnonzero_ok_\@:
    .endm

    .macro TEST_END
test_pass:
    la t5, test_signature
    sw zero, 0(t5)
    li t5, LED_ADDR
    li t6, PASS_VALUE
    sw t6, 0(t5)
.Lpass_halt:
    j .Lpass_halt

test_fail:
    la t5, test_signature
    lw t4, 0(t5)
    li t5, SEG_ADDR
    sw t4, 0(t5)
    li t5, LED_ADDR
    li t6, FAIL_VALUE
    sw t6, 0(t5)
.Lfail_halt:
    j .Lfail_halt

    .section .signature,"aw",@progbits
    .align 4
    .globl test_signature
test_signature:
    .word 0xffffffff
    .word 0xffffffff
    .word 0xffffffff
    .word 0xffffffff
    .endm

#endif
