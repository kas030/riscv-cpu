/* =============================================================
 * t15_string_ops.S —— 字符串/内存操作
 *
 * 实现并验证：
 *   strlen(s)       —— 找终止符
 *   memcpy(d,s,n)   —— 字节循环（不优化对齐）
 *   memset(d,c,n)   —— 字节循环填充
 *   strcmp(a,b)     —— 字节比较
 *
 * 这些是 C 标准库底层最常见的密集字节循环，能放大
 * load/store + 分支的开销。也是上层应用（UART 输出、
 * 命令行）必经之路。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    /* strlen("Hello RV32I!") == 12 */
    la      a0, hello
    jal     ra, strlen
    li      t0, 12
    bne     a0, t0, fail

    /* memcpy → buf2 */
    la      a0, buf2
    la      a1, hello
    li      a2, 13              # 含 NUL
    jal     ra, memcpy

    /* strcmp(buf2, hello) == 0 */
    la      a0, buf2
    la      a1, hello
    jal     ra, strcmp
    bnez    a0, fail

    /* memset(buf2, 'A', 8) 然后 strlen 应为 8 */
    la      a0, buf2
    li      a1, 'A'
    li      a2, 8
    jal     ra, memset
    /* 在第 8 字节后写 0 终止 */
    la      a0, buf2
    addi    a0, a0, 8
    sb      x0, 0(a0)
    la      a0, buf2
    jal     ra, strlen
    li      t0, 8
    bne     a0, t0, fail

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

/* size_t strlen(char *s) */
strlen:
    mv      t0, a0
sl_loop:
    lbu     t1, 0(t0)
    beqz    t1, sl_done
    addi    t0, t0, 1
    j       sl_loop
sl_done:
    sub     a0, t0, a0
    jalr    x0, ra, 0

/* void *memcpy(void *d=a0, void *s=a1, size_t n=a2) */
memcpy:
    mv      t0, a0              # 备份 d
mc_loop:
    beqz    a2, mc_done
    lbu     t1, 0(a1)
    sb      t1, 0(t0)
    addi    a1, a1, 1
    addi    t0, t0, 1
    addi    a2, a2, -1
    j       mc_loop
mc_done:
    jalr    x0, ra, 0

/* void *memset(void *d=a0, int c=a1, size_t n=a2) */
memset:
    mv      t0, a0
ms_loop:
    beqz    a2, ms_done
    sb      a1, 0(t0)
    addi    t0, t0, 1
    addi    a2, a2, -1
    j       ms_loop
ms_done:
    jalr    x0, ra, 0

/* int strcmp(char *a=a0, char *b=a1) */
strcmp:
sc_loop:
    lbu     t0, 0(a0)
    lbu     t1, 0(a1)
    bne     t0, t1, sc_diff
    beqz    t0, sc_eq
    addi    a0, a0, 1
    addi    a1, a1, 1
    j       sc_loop
sc_diff:
    sub     a0, t0, t1
    jalr    x0, ra, 0
sc_eq:
    li      a0, 0
    jalr    x0, ra, 0

    .section .rodata
hello:
    .ascii  "Hello RV32I!"
    .byte   0
    .align 2

    .section .data
buf2:
    .space  64
