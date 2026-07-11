/* cpop x7,x5: imm12=0x602, .word 0x60229393 */
    .section .text.init
    .globl _start
_start:
    li x5, 0xF0F0000F
    .word 0x60229393
    li x28, 12
    bne x7, x28, fail
    li x5, 0
    .word 0x60229393
    bne x7, x0, fail
    j pass
fail: li a0, 0xDEADBEEF
    j report
pass: li a0, 0xC0DEC0DE
report:
    lui t0, 0x80200
    addi t0, t0, 0x40
    sw a0, 0(t0)
1:  j 1b
