/* =============================================================
 * t16_quicksort.S —— 快速排序（递归）
 *
 * 经典 Lomuto 划分。对 64 元素整数数组排序。
 * 性能特点：
 *   - 大量递归调用（log N 深度），考察栈访问
 *   - 划分阶段密集 LW/SW + 比较分支
 *   - 与冒泡排序对比，可观察平均复杂度差异（O(N log N) vs O(N²)）
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    /* 拷贝原始数组到工作区 */
    la      a0, qs_src
    lui     a1, 0x80200
    addi    a1, a1, 0x500       # qs_work @ 0x80200500
    li      a2, 64
    jal     ra, copy_words

    /* qsort(arr, 0, 63) */
    lui     a0, 0x80200
    addi    a0, a0, 0x500
    li      a1, 0
    li      a2, 63
    jal     ra, quicksort

    /* 校验：相邻递增 */
    lui     s0, 0x80200
    addi    s0, s0, 0x500
    li      s1, 0
    li      s2, 63
chk:
    slli    t0, s1, 2
    add     t0, t0, s0
    lw      t1, 0(t0)
    lw      t2, 4(t0)
    bgt     t1, t2, fail
    addi    s1, s1, 1
    blt     s1, s2, chk

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

/* quicksort(arr=a0, lo=a1, hi=a2) */
quicksort:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      s0, 24(sp)
    sw      s1, 20(sp)
    sw      s2, 16(sp)
    sw      s3, 12(sp)
    bge     a1, a2, qs_ret
    mv      s0, a0
    mv      s1, a1
    mv      s2, a2
    /* partition(arr, lo, hi) → pivot index in a0 */
    jal     ra, partition
    mv      s3, a0              # pivot index (跨递归调用要保存)
    /* 左半 quicksort(arr, lo, pivot-1) */
    mv      a0, s0
    mv      a1, s1
    addi    a2, s3, -1
    jal     ra, quicksort
    /* 右半 quicksort(arr, pivot+1, hi) */
    mv      a0, s0
    addi    a1, s3, 1
    mv      a2, s2
    jal     ra, quicksort
qs_ret:
    lw      ra, 28(sp)
    lw      s0, 24(sp)
    lw      s1, 20(sp)
    lw      s2, 16(sp)
    lw      s3, 12(sp)
    addi    sp, sp, 32
    jalr    x0, ra, 0

/* partition(arr=a0, lo=a1, hi=a2) → pivot index in a0
 * 使用 a[hi] 为枢轴（Lomuto）
 */
partition:
    /* pivot = a[hi] */
    slli    t0, a2, 2
    add     t0, t0, a0
    lw      t1, 0(t0)           # pivot
    addi    t2, a1, -1          # i
    mv      t3, a1              # j
pa_loop:
    bge     t3, a2, pa_end
    slli    t4, t3, 2
    add     t4, t4, a0
    lw      t5, 0(t4)
    bge     t5, t1, pa_skip
    addi    t2, t2, 1
    /* swap a[i], a[j] */
    slli    t6, t2, 2
    add     t6, t6, a0
    lw      t0, 0(t6)
    sw      t5, 0(t6)
    sw      t0, 0(t4)
pa_skip:
    addi    t3, t3, 1
    j       pa_loop
pa_end:
    /* swap a[i+1], a[hi] */
    addi    t2, t2, 1
    slli    t6, t2, 2
    add     t6, t6, a0
    slli    t0, a2, 2
    add     t0, t0, a0
    lw      t1, 0(t0)
    lw      t5, 0(t6)
    sw      t1, 0(t6)
    sw      t5, 0(t0)
    mv      a0, t2              # 返回 pivot 索引
    jalr    x0, ra, 0

    .section .data
    .align 2
qs_src:
    .word 50, 23, 89,  4, 67, 12, 78, 31
    .word 56,  8, 91, 27, 73, 44, 19, 62
    .word 36, 14, 81,  6, 49, 25, 87, 38
    .word 71, 18, 53, 92, 47,  9, 85, 33
    .word 64, 21, 76, 41, 95, 58, 16, 83
    .word 28, 70, 11, 88, 39, 65,  3, 80
    .word 55, 24, 96, 17, 72, 46, 90, 32
    .word 60, 13, 84, 51,  7, 75, 22, 99
