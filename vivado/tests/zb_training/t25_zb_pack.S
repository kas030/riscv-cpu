/* pack x7,x5,x6: {x6[15:0],x5[15:0]}, .word 0x0862c3b3 */
    .section .text.init
    .globl _start
_start:
    li x5, 0xAAAABBBB
    li x6, 0xCCCCDDDD
    .word 0x0862c3b3
    li x28, 0xDDDDBBBB
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
