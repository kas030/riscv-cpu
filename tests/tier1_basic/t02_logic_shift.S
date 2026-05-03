/* =============================================================
 * t02_logic_shift.S —— 逻辑与移位指令测试
 *
 * 覆盖：AND/OR/XOR/ANDI/ORI/XORI
 *       SLL/SRL/SRA/SLLI/SRLI/SRAI
 *       LUI/AUIPC
 *
 * 重点：算术右移 SRA 与逻辑右移 SRL 的差别（符号位填充）。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* ---------- 按位运算 ---------- */
    li      x5,  0xF0F0F0F0
    li      x6,  0x0FF00FF0
    and     x7,  x5,  x6        # 0x00F000F0
    li      x28, 0x00F000F0
    bne     x7,  x28, fail

    or      x8,  x5,  x6        # 0xFFF0FFF0
    li      x28, 0xFFF0FFF0
    bne     x8,  x28, fail

    xor     x9,  x5,  x6        # 0xFF00FF00
    li      x28, 0xFF00FF00
    bne     x9,  x28, fail

    /* ---------- 立即数版本 ---------- */
    andi    x10, x5,  0xFF      # 0xF0
    li      x28, 0xF0
    bne     x10, x28, fail

    ori     x11, x0, 0x55
    xori    x12, x11, 0xFF      # 0x55 XOR 0xFF = 0xAA
    li      x28, 0xAA
    bne     x12, x28, fail

    /* ---------- 移位 ---------- */
    li      x13, 0x00000001
    slli    x14, x13, 31        # 0x80000000
    li      x28, 0x80000000
    bne     x14, x28, fail

    srli    x15, x14, 1         # 0x40000000 (逻辑右移)
    li      x28, 0x40000000
    bne     x15, x28, fail

    srai    x16, x14, 1         # 0xC0000000 (算术右移，符号扩展)
    li      x28, 0xC0000000
    bne     x16, x28, fail

    /* ---------- 寄存器移位 ---------- */
    li      x17, 4
    sll     x18, x13, x17       # 0x10
    li      x28, 0x10
    bne     x18, x28, fail

    /* ---------- LUI / AUIPC ---------- */
    lui     x19, 0x12345        # x19 = 0x12345000
    li      x28, 0x12345000
    bne     x19, x28, fail

    auipc   x20, 0              # x20 = 当前 PC
    /* 不直接断言，仅检查 AUIPC 不会崩 */

pass:
    li      a0, 0xC0DEC0DE
    j       done
fail:
    li      a0, 0xDEADBEEF
done:
    lui     t0, 0x80200
    addi    t0, t0, 0x3F00
    sw      a0, 0(t0)
1:  j       1b
