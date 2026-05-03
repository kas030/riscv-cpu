/* =============================================================
 * t14_prime_sieve.S —— 埃氏筛法（Sieve of Eratosthenes）
 *
 * 求 [2, N] 内所有素数。
 * 数据结构：bitmap（每 bit 表示一个数是否被筛掉）。
 *
 * N=255 → 54 个素数
 * 性能特点：
 *   - 大量随机访存（按 i*i, i*i+i, i*i+2i 步进写）
 *   - 位运算（位掩码）密集
 *   - 适合考察 Load/Store + AND/OR 流水线协同
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    /* 清零 bitmap：32 字节 = 256 bit */
    lui     t0, 0x80200
    addi    t0, t0, 0x400       # bitmap 起点
    li      t1, 8
clr:
    sw      x0, 0(t0)
    addi    t0, t0, 4
    addi    t1, t1, -1
    bnez    t1, clr

    /* 筛 */
    li      s0, 2               # i
    li      s1, 256             # N
    lui     s2, 0x80200
    addi    s2, s2, 0x400
sieve_outer:
    /* 检查 i 是否已被筛（is_marked(i)） */
    srli    t0, s0, 5           # word index = i / 32
    slli    t0, t0, 2
    add     t0, s2, t0
    lw      t1, 0(t0)
    andi    t2, s0, 31          # bit index
    li      t3, 1
    sll     t3, t3, t2
    and     t4, t1, t3
    bnez    t4, next_i          # 已被筛，跳过

    /* 标记 i*i, i*i+i, ... 直到 ≥ N */
    /* j = i*i：用循环加法实现 */
    li      t5, 0               # j = 0
    li      t6, 0               # cnt = 0
mul_jj:
    add     t5, t5, s0
    addi    t6, t6, 1
    blt     t6, s0, mul_jj
    /* 现在 t5 = i*i */
mark_loop:
    bge     t5, s1, next_i
    srli    t0, t5, 5
    slli    t0, t0, 2
    add     t0, s2, t0
    lw      t1, 0(t0)
    andi    t2, t5, 31
    li      t3, 1
    sll     t3, t3, t2
    or      t1, t1, t3
    sw      t1, 0(t0)
    add     t5, t5, s0
    j       mark_loop
next_i:
    addi    s0, s0, 1
    blt     s0, s1, sieve_outer

    /* 统计素数个数（未被筛掉的） */
    li      s0, 2
    li      s3, 0               # 计数
count:
    srli    t0, s0, 5
    slli    t0, t0, 2
    add     t0, s2, t0
    lw      t1, 0(t0)
    andi    t2, s0, 31
    li      t3, 1
    sll     t3, t3, t2
    and     t4, t1, t3
    bnez    t4, no_prime
    addi    s3, s3, 1
no_prime:
    addi    s0, s0, 1
    blt     s0, s1, count

    /* [2,256) 内素数个数 = 54 */
    li      t0, 54
    bne     s3, t0, fail
    /* 把素数计数显示到 LED */
    lui     t0, 0x80000
    sw      s3, 0(t0)

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
