/* =============================================================
 * t01_arith.S —— RV32I 算术 R/I 型指令功能测试
 *
 * 目标：在不依赖访存与跳转的前提下，独立验证
 *       ADD/ADDI/SUB/SLT/SLTU/SLTI/SLTIU 的功能正确性。
 *
 * 通过条件：所有断言均不触发 fail 分支，最终 a0 = 0xC0DEC0DE。
 *
 * 性能观察点：连续依赖运算，触发 EX→EX 前递（ForwardingUnit）。
 *           理想 CPI 应接近 1.0。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    /* ---------- 立即数加法/减法 ---------- */
    li      x5,  100            # x5 = 100
    addi    x6,  x5,  -50       # x6 = 50
    addi    x7,  x6,   25       # x7 = 75   (EX→EX 前递)
    li      x28, 75
    bne     x7,  x28, fail

    /* ---------- 寄存器加减 ---------- */
    add     x8,  x5,  x6        # x8 = 150  (依赖 x5/x6)
    sub     x9,  x8,  x7        # x9 = 75   (双源前递)
    bne     x9,  x28, fail

    /* ---------- 边界：溢出环绕 ---------- */
    li      x10, 0x7FFFFFFF
    addi    x11, x10, 1         # 0x80000000 (有符号溢出，正常环绕)
    li      x28, 0x80000000
    bne     x11, x28, fail

    /* ---------- SLT / SLTU ---------- */
    li      x12, -1
    li      x13,  1
    slt     x14, x12, x13       # -1 <s 1  → 1
    bne     x14, x13, fail
    sltu    x15, x12, x13       # 0xFFFFFFFF <u 1 → 0
    bne     x15, x0,  fail

    /* ---------- SLTI / SLTIU ---------- */
    slti    x16, x12, 0         # -1 <s 0 → 1
    bne     x16, x13, fail
    sltiu   x17, x12, 0         # 0xFFFFFFFF <u 0 → 0
    bne     x17, x0, fail

    /* ---------- 长依赖链（10 次连续 ADD，挑战前递） ---------- */
    li      x18, 0
    addi    x18, x18, 1
    addi    x18, x18, 2
    addi    x18, x18, 3
    addi    x18, x18, 4
    addi    x18, x18, 5
    addi    x18, x18, 6
    addi    x18, x18, 7
    addi    x18, x18, 8
    addi    x18, x18, 9
    addi    x18, x18, 10        # x18 = 1+2+...+10 = 55
    li      x28, 55
    bne     x18, x28, fail

pass:
    li      a0, 0xC0DEC0DE      # 成功标记
    j       done
fail:
    li      a0, 0xDEADBEEF      # 失败标记
done:
    /* 将结果写入 _result_addr，testbench 据此判定 */
    lui     t0, 0x80200
    addi    t0, t0, 0x3F00      # 0x802003F00 = _result_addr
    sw      a0, 0(t0)
1:  j       1b                  # 死循环停机
