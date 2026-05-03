/* =============================================================
 * t03_branch.S —— 条件分支与跳转指令测试
 *
 * 覆盖：BEQ/BNE/BLT/BGE/BLTU/BGEU
 *
 * 用途：检查
 *   - 控制冒险下分支是否正确刷新 IF/ID
 *   - 有符号 vs 无符号比较的差异
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    li      x5, 10
    li      x6, 20
    li      x7, -5

    /* BEQ */
    beq     x5, x5, l_beq_ok
    j       fail
l_beq_ok:
    bne     x5, x5, fail        # 不应跳

    /* BNE */
    bne     x5, x6, l_bne_ok
    j       fail
l_bne_ok:

    /* BLT (有符号) */
    blt     x7, x0, l_blt_ok    # -5 < 0
    j       fail
l_blt_ok:
    blt     x6, x5, fail        # 20 < 10 否

    /* BGE */
    bge     x6, x5, l_bge_ok
    j       fail
l_bge_ok:
    bge     x5, x6, fail

    /* BLTU (无符号) */
    bltu    x5, x6, l_bltu_ok
    j       fail
l_bltu_ok:
    /* x7 = -5 = 0xFFFFFFFB，无符号大于 x6=20 */
    bltu    x7, x6, fail        # 不应跳

    /* BGEU */
    bgeu    x7, x6, l_bgeu_ok   # 0xFFFFFFFB ≥ 20 (无符号)
    j       fail
l_bgeu_ok:

    /* ---------- 紧密相邻分支：流水线刷新压力测试 ---------- */
    li      x8, 0
    li      x9, 100
loop_pressure:
    addi    x8, x8, 1
    bne     x8, x9, loop_pressure   # 分支命中 99 次，最终 1 次失败
    /* x8 应当 = 100 */
    li      x28, 100
    bne     x8, x28, fail

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
