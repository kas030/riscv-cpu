/* =============================================================
 * t07_forwarding.S —— 数据前递（Forwarding）专项测试
 *
 * 目的：构造连续的 RAW（read-after-write）依赖序列，强制
 *       forwarding_unit 在 EX→EX、MEM→EX 之间进行数据前递。
 *       如果前递实现错误，结果将与黄金参考不符。
 *
 * 性能期望：所有依赖均可被前递解决，无气泡，CPI ≈ 1.0。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* -------- 模式 1：EX→EX（前一指令结果即时使用）-------- */
    li      t0, 1
    add     t1, t0, t0          # t1 = 2 (EX→EX)
    add     t2, t1, t1          # t2 = 4 (EX→EX，依赖 t1)
    add     t3, t2, t2          # t3 = 8
    add     t4, t3, t3          # t4 = 16
    add     t5, t4, t4          # t5 = 32
    add     t6, t5, t5          # t6 = 64
    li      t0, 64
    bne     t6, t0, fail

    /* -------- 模式 2：MEM→EX（隔一条指令使用） -------- */
    li      t0, 100
    addi    t1, t0, 0           # t1 = 100
    nop
    addi    t2, t1, 50          # t2 = 150 (MEM→EX 距离=2)
    li      t3, 150
    bne     t2, t3, fail

    /* -------- 模式 3：双源同时前递 -------- */
    li      t0, 7
    li      t1, 3
    sub     t2, t0, t1          # t2 = 4
    add     t3, t2, t2          # 双源都前递自 t2
    li      t4, 8
    bne     t3, t4, fail

    /* -------- 模式 4：写 x0 不应改变寄存器堆 -------- */
    li      x0, 999             # 应被忽略（架构上 x0 永远 = 0）
    add     t0, x0, x0
    bne     t0, x0, fail

    /* -------- 模式 5：累加 1000 次（前递热身） -------- */
    li      t0, 0
    li      t1, 1000
acc_loop:
    addi    t0, t0, 1
    addi    t0, t0, 1           # 紧密 RAW
    addi    t0, t0, 1
    addi    t0, t0, 1
    addi    t1, t1, -4
    bgtz    t1, acc_loop
    li      t2, 1000
    bne     t0, t2, fail

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
