/* =============================================================
 * t12_matmul.S —— 4×4 整数矩阵乘法基准
 *
 * 计算 C = A × B，其中 A、B、C 均为 4×4 int32 矩阵。
 * 由于 RV32I 没有乘法指令，使用"移位-加法"的 32 位无符号乘法子例程。
 *
 * 重点：
 *   - 三重循环 + 软件乘法 → 周期数显著
 *   - 寄存器分配紧张，编译器（手写）必须仔细安排栈帧
 *   - 大量 LW/SW 访存，是 cache-less 设计下访存带宽的考验
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    /* 拷贝 A、B 到工作区，C 清零 */
    la      a0, mat_a
    lui     a1, 0x80200
    addi    a1, a1, 0x300       # workA  @ 0x80200300
    li      a2, 16
    jal     ra, copy_words
    la      a0, mat_b
    lui     a1, 0x80200
    addi    a1, a1, 0x340       # workB  @ 0x80200340
    li      a2, 16
    jal     ra, copy_words

    /* 调用 matmul4(A,B,C) */
    lui     a0, 0x80200
    addi    a0, a0, 0x300
    lui     a1, 0x80200
    addi    a1, a1, 0x340
    lui     a2, 0x80200
    addi    a2, a2, 0x380       # workC  @ 0x80200380
    jal     ra, matmul4

    /* 校验 C[0][0]：与 A、B 数据相关 */
    lw      t0, 0(a2)
    li      t1, 90              # 与下方数据矩阵的预算结果一致
    bne     t0, t1, fail

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

/* mul32(a0,a1)→a0 （shift-and-add 无符号 32×32→32） */
mul32:
    li      t0, 0               # 累加器
    li      t1, 32              # 计数
mul_loop:
    andi    t2, a1, 1
    beqz    t2, mul_skip
    add     t0, t0, a0
mul_skip:
    slli    a0, a0, 1
    srli    a1, a1, 1
    addi    t1, t1, -1
    bnez    t1, mul_loop
    mv      a0, t0
    jalr    x0, ra, 0

/* copy_words(dst=a1, src=a0, n=a2) */
copy_words:
    beqz    a2, cw_done
cw_loop:
    lw      t0, 0(a0)
    sw      t0, 0(a1)
    addi    a0, a0, 4
    addi    a1, a1, 4
    addi    a2, a2, -1
    bnez    a2, cw_loop
cw_done:
    jalr    x0, ra, 0

/* matmul4(A=a0, B=a1, C=a2)：4×4 矩阵乘
 * 寄存器：
 *   s0=A_base, s1=B_base, s2=C_base
 *   s3=i, s4=j, s5=k
 *   s6=acc
 */
matmul4:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)
    sw      s4,  8(sp)
    sw      s5,  4(sp)
    sw      s6,  0(sp)
    mv      s0, a0
    mv      s1, a1
    mv      s2, a2
    li      s3, 0               # i
mm_i:
    li      s4, 0               # j
mm_j:
    li      s5, 0               # k
    li      s6, 0               # acc
mm_k:
    /* 计算 a_addr = A + (i*4+k)*4 */
    slli    t0, s3, 2
    add     t0, t0, s5
    slli    t0, t0, 2
    add     t0, t0, s0
    lw      a0, 0(t0)           # A[i][k]
    /* b_addr = B + (k*4+j)*4 */
    slli    t1, s5, 2
    add     t1, t1, s4
    slli    t1, t1, 2
    add     t1, t1, s1
    lw      a1, 0(t1)           # B[k][j]
    jal     ra, mul32           # a0 = A*B
    add     s6, s6, a0
    addi    s5, s5, 1
    li      t0, 4
    blt     s5, t0, mm_k
    /* 写 C[i][j] */
    slli    t0, s3, 2
    add     t0, t0, s4
    slli    t0, t0, 2
    add     t0, t0, s2
    sw      s6, 0(t0)
    addi    s4, s4, 1
    li      t0, 4
    blt     s4, t0, mm_j
    addi    s3, s3, 1
    li      t0, 4
    blt     s3, t0, mm_i

    lw      ra, 28(sp)
    lw      s0, 24(sp)
    lw      s1, 20(sp)
    lw      s2, 16(sp)
    lw      s3, 12(sp)
    lw      s4,  8(sp)
    lw      s5,  4(sp)
    lw      s6,  0(sp)
    addi    sp, sp, 32
    jalr    x0, ra, 0

    .section .data
    .align 2
    .globl mat_a
mat_a:
    .word 1, 2, 3, 4
    .word 5, 6, 7, 8
    .word 9, 10, 11, 12
    .word 13, 14, 15, 16

    .globl mat_b
mat_b:
    .word 1, 2, 3, 4
    .word 5, 6, 7, 8
    .word 9, 10, 11, 12
    .word 13, 14, 15, 16
    /* C[0][0] = 1*1 + 2*5 + 3*9 + 4*13 = 1+10+27+52 = 90 ✓ */
