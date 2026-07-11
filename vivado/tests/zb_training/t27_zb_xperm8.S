/* xperm8 x7,x5,x6: .word 0x2862c3b3 */
    .section .text.init
    .globl _start
_start:
    li x5, 0x44332211
    li x6, 0x00010203
    .word 0x2862c3b3
    li x28, 0x11223344
    bne x7, x28, fail
    li x6, 0x04010203       /* 索引 4 越界，对应输出字节应清零 */
    .word 0x2862c3b3
    li x28, 0x00223344
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
