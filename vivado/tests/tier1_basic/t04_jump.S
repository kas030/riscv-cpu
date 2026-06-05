/* =============================================================
 * t04_jump.S —— JAL / JALR 子程序调用测试
 *
 * 验证：
 *   - JAL 链接寄存器写入正确
 *   - JALR 任意目标跳转
 *   - 嵌套调用（栈帧管理）
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* 设置栈指针 */
    lui     sp, 0x80201         # sp = 0x80201000 (BRAM 顶端附近)

    /* 调用 add5(10) → 期望 15 */
    li      a0, 10
    jal     ra, add5
    li      x28, 15
    bne     a0, x28, fail

    /* 调用斐波那契 fib(10) → 期望 55 */
    li      a0, 10
    jal     ra, fib
    li      x28, 55
    bne     a0, x28, fail

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

/* -------- 简单叶子函数 -------- */
add5:
    addi    a0, a0, 5
    jalr    x0, ra, 0           # ret

/* -------- 递归 fib：fib(n)=fib(n-1)+fib(n-2) ----------
 * 入口：a0 = n
 * 出口：a0 = fib(n)
 * 使用：栈保存 ra, n, t1
 * 性能意义：高频 JALR 与 LW/SW，考察 load-use 冒险与栈访问。
 * ------------------------------------------------------ */
fib:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      a0,  8(sp)          # 保存 n
    li      t0, 2
    blt     a0, t0, fib_base    # n < 2 直接返回 n
    addi    a0, a0, -1
    jal     ra, fib             # fib(n-1)
    sw      a0,  4(sp)          # 暂存 fib(n-1)
    lw      a0,  8(sp)
    addi    a0, a0, -2
    jal     ra, fib             # fib(n-2)
    lw      t1,  4(sp)
    add     a0, a0, t1
fib_ret:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    jalr    x0, ra, 0
fib_base:
    /* a0 已经是 0 或 1，直接返回 */
    j       fib_ret
