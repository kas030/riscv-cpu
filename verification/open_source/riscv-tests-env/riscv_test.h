#ifndef RISCV_CPU_RISCV_TEST_H
#define RISCV_CPU_RISCV_TEST_H

#define TESTNUM x3
#define RVTEST_RV32U
#define RVTEST_RV64U

#define RVTEST_CODE_BEGIN \
    .option norvc; \
    .option norelax; \
    .section .text.init; \
    .globl _start; \
_start: \
    li sp, 0x8013fff0; \
    j rvtest_code_start; \
    .section .text; \
rvtest_code_start:

#define RVTEST_CODE_END

#define RVTEST_PASS \
    li t5, 0x80200040; \
    li t6, 0xc0dec0de; \
    sw t6, 0(t5); \
1:  j 1b;

#define RVTEST_FAIL \
    li t5, 0x80200020; \
    sw TESTNUM, 0(t5); \
    la t5, rvtest_signature; \
    sw TESTNUM, 0(t5); \
    li t5, 0x80200040; \
    li t6, 0xdeadbeef; \
    sw t6, 0(t5); \
1:  j 1b;

#define RVTEST_DATA_BEGIN \
    .align 4; \
    .globl rvtest_signature; \
rvtest_signature: \
    .word 0xffffffff;

#define RVTEST_DATA_END

#endif
