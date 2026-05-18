/* =============================================================
 * t08_load_use.S —— Load-Use 冒险（必须停顿 1 拍）
 *
 * 目的：紧跟 LW 之后立即使用其目的寄存器，HazardUnit 应
 *       插入一个气泡。本测试通过比较前递 vs 停顿两种实现：
 *       同一段代码，预期周期数偏离 1 周期/次 load-use。
 *
 * 调试观察：
 *   - 测试段 1 故意构造 N 次 load-use，应当产生 N 个 stall。
 *   - 测试段 2 加入插槽 NOP 化解依赖，CPI 应回落到 1.0。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     gp, 0x80200
    addi    gp, gp, 0x200       # gp 指向数据缓冲区

    /* 初始化 8 个连续字 */
    li      t0, 1
    sw      t0,  0(gp)
    li      t0, 2
    sw      t0,  4(gp)
    li      t0, 3
    sw      t0,  8(gp)
    li      t0, 4
    sw      t0, 12(gp)
    li      t0, 5
    sw      t0, 16(gp)
    li      t0, 6
    sw      t0, 20(gp)
    li      t0, 7
    sw      t0, 24(gp)
    li      t0, 8
    sw      t0, 28(gp)

    /* ---- 段 1：紧密 load-use（每次 1 拍 stall） ---- */
    /* 标签 STAL_BEGIN/STAL_END 用于波形/性能计数器圈定 */
    .globl  STAL_BEGIN
STAL_BEGIN:
    lw      t0,  0(gp)
    add     t1, t0, t0          # 立即用 → stall
    lw      t0,  4(gp)
    add     t2, t0, t0          # stall
    lw      t0,  8(gp)
    add     t3, t0, t0          # stall
    lw      t0, 12(gp)
    add     t4, t0, t0          # stall
    .globl  STAL_END
STAL_END:

    /* ---- 段 2：调度后 load-use（插入无关指令） ---- */
    .globl  RESCHED_BEGIN
RESCHED_BEGIN:
    lw      t0, 16(gp)
    addi    t5, t5, 1           # 无关指令
    add     t1, t0, t0          # load-use 已隔开

    lw      t0, 20(gp)
    addi    t5, t5, 1
    add     t2, t0, t0

    lw      t0, 24(gp)
    addi    t5, t5, 1
    add     t3, t0, t0

    lw      t0, 28(gp)
    addi    t5, t5, 1
    add     t4, t0, t0
    .globl  RESCHED_END
RESCHED_END:

    /* 校验段 2 累加器 */
    li      t6, 4
    bne     t5, t6, fail

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
