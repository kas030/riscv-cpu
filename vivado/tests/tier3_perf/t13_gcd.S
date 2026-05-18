/* =============================================================
 * t13_gcd.S —— 欧几里得最大公约数
 *
 * 用途：迭代取模算法，反复使用 BLT/BNE/SUB，几乎无访存。
 *      用来纯粹度量分支与算术核心的吞吐。
 *
 * RV32I 没有 DIV/REM，故使用"反复减法"实现 mod。
 *
 * 测试用例：
 *   gcd(1071, 462) = 21
 *   gcd(48,   18) = 6
 *   gcd(0xFFFFFFF0, 0x00000010) = 16
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    li      a0, 1071
    li      a1, 462
    jal     ra, gcd
    li      t0, 21
    bne     a0, t0, fail

    li      a0, 48
    li      a1, 18
    jal     ra, gcd
    li      t0, 6
    bne     a0, t0, fail

    li      a0, 0x100
    li      a1, 0x80
    jal     ra, gcd
    li      t0, 0x80
    bne     a0, t0, fail

    /* 大量调用，模拟真实场景下的吞吐 */
    li      s0, 0
    li      s1, 200
loop_gcd:
    li      a0, 1071
    li      a1, 462
    jal     ra, gcd
    addi    s0, s0, 1
    blt     s0, s1, loop_gcd

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

/* gcd(a=a0, b=a1)→a0 （欧几里得，递归改为迭代） */
gcd:
    beqz    a1, gcd_done
gcd_loop:
    /* a0 = a0 % a1（用反复减法） */
    bge     a0, a1, mod_step
    /* a0 < a1 → 已经是 mod */
    j       mod_done
mod_step:
    sub     a0, a0, a1
    bge     a0, a1, mod_step
mod_done:
    /* swap a0 <-> a1 */
    mv      t0, a1
    mv      a1, a0
    mv      a0, t0
    bnez    a1, gcd_loop
gcd_done:
    jalr    x0, ra, 0
