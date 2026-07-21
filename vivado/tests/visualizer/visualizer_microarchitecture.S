/* 可视化器专用微架构覆盖场景。
 * 覆盖地址 lane、L0 miss/hit 紧邻依赖、双消费者、WAW，以及错路径
 * store/CSR 的副作用抑制。已有 t18/t19 分别负责 M busy 与 trap 细节。
 */
    .option norvc
    .section .text.init
    .globl _start
_start:
    lui     gp, 0x80100
    addi    gp, gp, 0x300

    /* t03 已覆盖 BGEU taken；这里补齐明确的 not-taken 动态实例。 */
    li      t0, 1
    li      t1, 2
    bgeu    t0, t1, fail

    /* byte/half 的高地址 lane 与符号扩展。 */
    li      t0, 0x80ff7f01
    sw      t0, 0(gp)
    lb      t1, 2(gp)
    li      t2, -1
    bne     t1, t2, fail
    lbu     t1, 3(gp)
    li      t2, 0x80
    bne     t1, t2, fail
    lh      t1, 2(gp)
    li      t2, 0xffff80ff
    bne     t1, t2, fail
    lhu     t1, 2(gp)
    li      t2, 0x000080ff
    bne     t1, t2, fail

    /* 四个 byte lane 与两个 half lane，随后按完整字核对。 */
    li      t0, 0x11
    sb      t0, 0(gp)
    li      t0, 0x22
    sb      t0, 1(gp)
    li      t0, 0x33
    sb      t0, 2(gp)
    li      t0, 0x44
    sb      t0, 3(gp)
    lw      t1, 0(gp)
    li      t2, 0x44332211
    bne     t1, t2, fail
    li      t0, 0x6677
    sh      t0, 0(gp)
    li      t0, 0x8899
    sh      t0, 2(gp)
    lw      t1, 0(gp)
    li      t2, 0x88996677
    bne     t1, t2, fail

    /* 第一次 miss 填充；第二次 hit 后的依赖 add 应直接取得 L0 数据。 */
    lw      s1, 0(gp)
    addi    zero, zero, 0
    addi    zero, zero, 0
    addi    zero, zero, 0
    lw      s2, 0(gp)
    add     s3, s2, s2
    add     s3, s3, zero

    /* 重复回访训练 hint：两条 load 后的两个消费者能够形成双槽组合。 */
    li      s4, 0
    li      s5, 4
dual_consumer_loop:
    lw      a1, 0(gp)
    lw      a2, 4(gp)
    add     a3, a1, a2
    add     a4, a2, a1
    addi    s4, s4, 1
    blt     s4, s5, dual_consumer_loop

    /* 同 rd WAW：按槽 0、槽 1 顺序提交，最终保留年轻槽的 2。 */
    li      s4, 0
waw_loop:
    addi    t1, zero, 1
    addi    t1, zero, 2
    addi    s4, s4, 1
    blt     s4, s5, waw_loop
    li      t2, 2
    bne     t1, t2, fail

    /* forward branch 冷启动预测不跳；下面的 store/CSR 必须都被 flush。 */
    sw      zero, 16(gp)
    li      s6, 0x55
    .word   0x340b1073          /* csrrw zero, mscratch, s6 */
    beq     zero, zero, wrong_path_target
    sw      s6, 16(gp)
    .word   0x34001073          /* csrrw zero, mscratch, zero */
    addi    s6, zero, -1
wrong_path_target:
    lw      t1, 16(gp)
    bne     t1, zero, fail
    .word   0x34002373          /* csrrs t1, mscratch, zero */
    li      t2, 0x55
    bne     t1, t2, fail

    /* JALR 使用 EX 解析的目标，覆盖未预测目标重定向。 */
    la      t0, jalr_target
    lui     t2, 0x80000
    add     t0, t0, t2
    jalr    zero, 0(t0)
    sw      s6, 20(gp)
jalr_target:
    lw      t1, 20(gp)
    bne     t1, zero, fail

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
