/* brev8 x7,x5: imm12=0x687, .word 0x6872d393 */
    .section .text.init
    .globl _start
_start:
    li x5, 0x01234567
    .word 0x6872d393
    li x28, 0x80C4A2E6
    bne x7, x28, fail
    j pass
fail: li a0, 0xDEADBEEF
    j report
pass: li a0, 0xC0DEC0DE
report:
    lui t0, 0x80200
    addi t0, t0, 0x40
    sw a0, 0(t0)
1:  j 1b
