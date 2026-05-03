/* =============================================================
 * t05_load_store.S —— 访存指令测试
 *
 * 覆盖：LB/LH/LW/LBU/LHU + SB/SH/SW
 *
 * 重点：
 *   - 字节/半字符号扩展是否正确
 *   - 非对齐写入字节后再用 LW 读回的合并
 *   - load-use 冒险（紧跟在 LW 后的依赖指令需要 1 周期 stall）
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     gp, 0x80200
    addi    gp, gp, 0x100       # gp = 测试缓冲区 0x80200100

    /* ---------- SW + LW ---------- */
    li      t0, 0xDEADBEEF
    sw      t0, 0(gp)
    lw      t1, 0(gp)           # load-use：紧接断言会触发 stall
    bne     t0, t1, fail

    /* ---------- SH + LH/LHU ---------- */
    li      t0, 0xFFFF8000      # 半字写值（带符号）
    sh      t0, 4(gp)
    lh      t1, 4(gp)           # 应为 0xFFFF8000 (符号扩展)
    li      t2, 0xFFFF8000
    bne     t1, t2, fail
    lhu     t1, 4(gp)           # 应为 0x00008000 (零扩展)
    li      t2, 0x00008000
    bne     t1, t2, fail

    /* ---------- SB + LB/LBU ---------- */
    li      t0, 0xFFFFFF80      # 字节 = 0x80
    sb      t0, 8(gp)
    lb      t1, 8(gp)           # 0xFFFFFF80
    li      t2, 0xFFFFFF80
    bne     t1, t2, fail
    lbu     t1, 8(gp)           # 0x00000080
    li      t2, 0x00000080
    bne     t1, t2, fail

    /* ---------- 字节级写入构造一个 32 位字 ---------- */
    sb      x0, 12(gp)          # 先清零 4 字节
    sb      x0, 13(gp)
    sb      x0, 14(gp)
    sb      x0, 15(gp)
    li      t0, 0x11
    sb      t0, 12(gp)
    li      t0, 0x22
    sb      t0, 13(gp)
    li      t0, 0x33
    sb      t0, 14(gp)
    li      t0, 0x44
    sb      t0, 15(gp)
    lw      t1, 12(gp)          # 小端：应得到 0x44332211
    li      t2, 0x44332211
    bne     t1, t2, fail

    /* ---------- 数组求和（顺序访存性能样本） ---------- */
    li      t0, 0
    addi    t1, gp, 0x40
    li      t2, 0
init_loop:
    sw      t1, 0(t1)           # 简单填充：a[i] = &a[i]
    addi    t1, t1, 4
    addi    t2, t2, 1
    li      t3, 16
    blt     t2, t3, init_loop

    addi    t1, gp, 0x40
    li      t2, 0
    li      t0, 0
sum_loop:
    lw      t4, 0(t1)
    add     t0, t0, t4          # load-use 冒险
    addi    t1, t1, 4
    addi    t2, t2, 1
    li      t3, 16
    blt     t2, t3, sum_loop

    /* 校验：t0 = 16 个连续地址之和（不严格断言数值，只需未挂起） */

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
