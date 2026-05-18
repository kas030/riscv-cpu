/* =============================================================
 * t10_fibonacci.S —— 斐波那契性能基准
 *
 * 含两段实现以对比性能：
 *   - fib_iter(n) ：迭代版本，O(n)，主要是 ADD + 分支
 *   - fib_rec(n)  ：递归版本，O(2^n)，密集 JAL/JALR + 栈访问
 *
 * 输入 n=20：
 *   - 期望 fib(20) = 6765
 *
 * 性能指标（参考）：
 *   - 假设 CPU 主频 50MHz：
 *     fib_iter(20) ≈ 数百周期 → < 10 µs
 *     fib_rec(20)  ≈ 数十万周期 → 数 ms（用于压栈/调用开销分析）
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201         # 栈指针

    /* 迭代 */
    li      a0, 20
    jal     ra, fib_iter
    li      t0, 6765
    bne     a0, t0, fail
    /* 把迭代结果写入 LED 用于上板验证 */
    lui     t0, 0x80000
    sw      a0, 0(t0)

    /* 递归 */
    li      a0, 15              # 递归用较小 n 控制时间
    jal     ra, fib_rec
    li      t0, 610
    bne     a0, t0, fail

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

/* fib_iter(n)：a0 输入 n，返回 fib(n) */
fib_iter:
    li      t0, 0               # a = 0
    li      t1, 1               # b = 1
    beqz    a0, fib_iter_done
fil_loop:
    add     t2, t0, t1          # c = a+b
    mv      t0, t1              # a = b
    mv      t1, t2              # b = c
    addi    a0, a0, -1
    bnez    a0, fil_loop
    mv      a0, t0
    jalr    x0, ra, 0
fib_iter_done:
    mv      a0, t0
    jalr    x0, ra, 0

/* fib_rec(n)：递归版 */
fib_rec:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      a0,  8(sp)
    li      t0, 2
    blt     a0, t0, frec_base
    addi    a0, a0, -1
    jal     ra, fib_rec
    sw      a0, 4(sp)
    lw      a0, 8(sp)
    addi    a0, a0, -2
    jal     ra, fib_rec
    lw      t1, 4(sp)
    add     a0, a0, t1
frec_ret:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    jalr    x0, ra, 0
frec_base:
    j       frec_ret
