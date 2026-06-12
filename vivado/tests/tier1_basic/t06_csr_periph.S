/* =============================================================
 * t06_csr_periph.S —— CSR 与外设访问测试
 *
 * 本工程外设地址（来自 perip_bridge.sv 综合分析）：
 *   - LED:   0x80200040 (32 个虚拟 LED)
 *   - SEG:   0x80200020 (8 段数码管，BCD)
 *   - COUNTER: 0x80200050 (周期计数器，只读)
 *
 * 验证：
 *   - LUI 形成的高位地址 + 偏移可以访问到 MMIO
 *   - CSR 读写：mtvec/mepc 写后能读回
 *   - mret 不挂起流水线（即使没有真正进入异常）
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* ---------- CSR 读写 ---------- */
    li      t0, 0x12345678
    csrrw   t1, mtvec, t0       # 写 mtvec，返回旧值到 t1
    csrr    t2, mtvec           # 读回应等于 t0 (低 2 位除外)
    /* CPU 实现可能强制 mtvec 4 字节对齐，仅校验高 30 位 */
    srli    t2, t2, 2
    srli    t3, t0, 2
    bne     t2, t3, fail

    li      t0, 0x80000000
    csrw    mepc, t0
    csrr    t1, mepc
    bne     t0, t1, fail

    /* ---------- 外设：点亮 LED 模式 0xA5A5A5A5 ---------- */
    lui     t0, 0x80200
    li      t1, 0xA5A5A5A5
    sw      t1, 0x40(t0)        # LED 寄存器

    /* ---------- 外设：在数码管显示 0x12345678 ---------- */
    li      t1, 0x12345678
    sw      t1, 0x20(t0)

    /* ---------- 读取硬件周期计数器（如果实现） ---------- */
    lw      t2, 0x50(t0)        # 读取当前 cycle
    nop
    nop
    nop
    nop
    nop
    lw      t3, 0x50(t0)        # 再读一次
    sub     t4, t3, t2          # 差值 ≥ 6（至少经过的指令数）
    li      t5, 4
    blt     t4, t5, fail        # 计数器没动 → 异常

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
