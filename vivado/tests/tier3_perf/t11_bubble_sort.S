/* =============================================================
 * t11_bubble_sort.S —— 冒泡排序性能基准
 *
 * 数据：32 个 32 位整数（数据存于 .data 段，供 BRAM.coe 初始化）
 * 算法：经典冒泡排序，外层 N-1 次，内层每次少 1 次比较
 * 时间复杂度：O(N²)；本例 N=32 → 992 次比较，最多同样次数交换
 *
 * 性能意义：
 *   - 高频访存（每次比较 2 次 LW）
 *   - 紧密分支（内层循环边界判定）
 *   - 显著的 load-use 冒险，是 stall 数量的主要来源
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80140
    /* 把数组从 .data 拷到工作区（BRAM 0x80100200） */
    la      a0, src_arr
    lui     a1, 0x80100
    addi    a1, a1, 0x200
    li      a2, 32
    jal     ra, copy_words

    /* 调用排序 */
    lui     a0, 0x80100
    addi    a0, a0, 0x200
    li      a1, 32
    jal     ra, bubble_sort

    /* 校验：a[0] 应为最小值 1，a[31] 应为最大值 32 */
    lui     a0, 0x80100
    addi    a0, a0, 0x200
    lw      t0, 0(a0)
    li      t1, 1
    bne     t0, t1, fail
    lw      t0, 124(a0)
    li      t1, 32
    bne     t0, t1, fail

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

/* bubble_sort(arr=a0, n=a1) */
bubble_sort:
    addi    t0, a1, -1          # i = n-1
bs_outer:
    blez    t0, bs_done
    li      t1, 0               # j = 0
    mv      t2, a0              # ptr
bs_inner:
    lw      t3, 0(t2)
    lw      t4, 4(t2)
    bge     t4, t3, bs_skip     # a[j+1] >= a[j] 不换
    sw      t4, 0(t2)
    sw      t3, 4(t2)
bs_skip:
    addi    t2, t2, 4
    addi    t1, t1, 1
    blt     t1, t0, bs_inner
    addi    t0, t0, -1
    j       bs_outer
bs_done:
    jalr    x0, ra, 0

    .section .data
    .align 2
    .globl src_arr
src_arr:
    /* 32 个乱序整数（性能基准用） */
    .word  17, 31,  4, 22,  9, 27, 14,  2
    .word  19, 11, 30, 25,  6, 16, 28,  8
    .word  21,  3, 13, 26, 10, 24, 20,  5
    .word  29, 15,  1, 32, 18, 12, 23,  7
