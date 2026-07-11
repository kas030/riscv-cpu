/* ror x7,x5,x6: .word 0x6062d3b3 */
    .section .text.init
    .globl _start
_start:
    li x5, 0x80000001
    li x6, 1
    .word 0x6062d3b3
    li x28, 0xC0000000
    bne x7, x28, fail
    li x6, 0
    .word 0x6062d3b3
    bne x7, x5, fail
    j pass
fail: li a0, 0xDEADBEEF
    j report
pass: li a0, 0xC0DEC0DE
report:
    lui t0, 0x80200
    addi t0, t0, 0x40
    sw a0, 0(t0)
1:  j 1b
