/* =============================================================
 * t09_branch_hazard.S —— 控制冒险与分支刷新测试
 *
 * 在 IF 取的“紧跟 BNE 之后那条指令”如果未被刷新，会污染寄存器。
 * 我们用一段会“写入危险值”的影子代码紧跟分支，
 * 如果 NPC 控制错误（未冲刷 IF/ID）则该影子会污染寄存器，触发 fail。
 *
 * 同时混入 backward / forward 两种方向、不同距离的分支，
 * 模拟真实程序中的 if/while/for 模式。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    li      s0, 0               # s0 = "陷阱触发计数"

    /* ---------- forward 短分支 ---------- */
    li      t0, 5
    li      t1, 5
    beq     t0, t1, l1          # 必跳
    addi    s0, s0, 1           # 不应执行
    addi    s0, s0, 1           # 不应执行
l1:
    /* ---------- forward 长分支 ---------- */
    li      t0, 10
    bnez    t0, l2              # 必跳
    addi    s0, s0, 1
    addi    s0, s0, 1
    addi    s0, s0, 1
    addi    s0, s0, 1
l2:
    /* ---------- backward 循环（taken 多次） ---------- */
    li      t2, 0
    li      t3, 50
loop_b:
    addi    t2, t2, 1
    bne     t2, t3, loop_b      # 49 次 taken，1 次 not-taken
    li      t4, 50
    bne     t2, t4, fail

    /* ---------- 紧密 if-else 链（高频分支） ---------- */
    li      t0, 0
    li      t1, 100
    li      t2, 0               # 偶数计数
    li      t3, 0               # 奇数计数
chain_loop:
    andi    t4, t0, 1
    beqz    t4, even_branch
    addi    t3, t3, 1
    j       chain_next
even_branch:
    addi    t2, t2, 1
chain_next:
    addi    t0, t0, 1
    bne     t0, t1, chain_loop
    /* 期望：奇数 50，偶数 50 */
    li      t4, 50
    bne     t2, t4, fail
    bne     t3, t4, fail

    /* 影子计数应仍为 0 */
    bnez    s0, fail

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
