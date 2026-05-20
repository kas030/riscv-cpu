/* =============================================================
 * t18_m_ext_basic.S —— RV32M 基础功能测试
 *
 * 覆盖：
 *   MUL / MULH / MULHSU / MULHU
 *   DIV / DIVU / REM / REMU
 *
 * 同时检查 RISC-V 标准定义的两个关键边界：
 *   1. 除数为 0
 *   2. 0x80000000 / -1 的有符号溢出
 *
 * 通过条件：所有断言均通过，最终 a0 = 0xC0DEC0DE。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* ---------- 乘法低位 ---------- */
    li      x5,  7
    li      x6, -3
    mul     x7,  x5, x6
    li      x28, -21
    bne     x7,  x28, fail

    /* ---------- 乘法高位：signed / signed ---------- */
    li      x5, -1
    li      x6,  2
    mulh    x7,  x5, x6
    li      x28, -1
    bne     x7,  x28, fail

    /* ---------- 乘法高位：signed / unsigned ---------- */
    mulhsu  x7,  x5, x6
    li      x28, -1
    bne     x7,  x28, fail

    /* ---------- 乘法高位：unsigned / unsigned ---------- */
    li      x5, -1
    li      x6,  2
    mulhu   x7,  x5, x6
    li      x28, 1
    bne     x7,  x28, fail

    /* ---------- 有符号除法与取余 ---------- */
    li      x5, -20
    li      x6,  3
    div     x7,  x5, x6
    li      x28, -6
    bne     x7,  x28, fail

    rem     x7,  x5, x6
    li      x28, -2
    bne     x7,  x28, fail

    /* ---------- 无符号除法与取余 ---------- */
    li      x5, 20
    li      x6, 3
    divu    x7, x5, x6
    li      x28, 6
    bne     x7, x28, fail

    remu    x7, x5, x6
    li      x28, 2
    bne     x7, x28, fail

    /* ---------- 除零特殊情况 ---------- */
    li      x5, 123
    li      x6, 0
    div     x7, x5, x6
    li      x28, -1
    bne     x7, x28, fail

    divu    x7, x5, x6
    li      x28, -1
    bne     x7, x28, fail

    rem     x7, x5, x6
    li      x28, 123
    bne     x7, x28, fail

    remu    x7, x5, x6
    li      x28, 123
    bne     x7, x28, fail

    /* ---------- 有符号溢出特殊情况 ---------- */
    li      x5, 0x80000000
    li      x6, -1
    div     x7, x5, x6
    li      x28, 0x80000000
    bne     x7, x28, fail

    rem     x7, x5, x6
    bne     x7, x0, fail

pass:
    li      a0, 0xC0DEC0DE
    j       done
fail:
    li      a0, 0xDEADBEEF
done:
    lui     t0, 0x80200
    addi    t0, t0, 0x40
    sw      a0, 0(t0)
1:  j       1b
