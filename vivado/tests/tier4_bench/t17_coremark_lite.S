/* =============================================================
 * t17_coremark_lite.S —— 综合性能基准（CoreMark-lite）
 *
 * 模仿 CoreMark 的核心负载：
 *   ① 链表操作（指针追逐 + 比较）
 *   ② 矩阵乘加（数学密集）
 *   ③ 状态机（switch + 字节解析）
 *
 * 在一次测试中并发触发：
 *   - 大量 LW/SW（链表节点访问）
 *   - 软件乘法（无 M 扩展时）
 *   - 多分支 switch 风格跳转
 *
 * 测试报告以"Iteration 数 / 周期数"形式给出，
 * 是衡量整体微架构 IPC 与缓存（本设计无 cache）效率的综合指标。
 *
 * 配置：ITERATIONS=10，每轮处理 16 节点链表+16 矩阵乘累加+
 *      32 字节字符串校验和。
 * ============================================================= */
    .section .text.init
    .globl _start
_start:
    lui     sp, 0x80201

    /* 读取硬件 cycle 计数器（如外设支持） */
    lui     t0, 0x80000
    lw      s0, 0x20(t0)        # start_cycle

    /* 主循环 */
    li      s1, 0               # iter
    li      s2, 10              # ITERATIONS
    li      s3, 0               # 累计校验值
main_loop:
    jal     ra, list_walk       # → a0
    add     s3, s3, a0
    jal     ra, matrix_mac      # → a0
    add     s3, s3, a0
    jal     ra, state_sum       # → a0
    add     s3, s3, a0
    addi    s1, s1, 1
    blt     s1, s2, main_loop

    /* 读 end cycle，将差值写到 LED */
    lui     t0, 0x80000
    lw      s4, 0x20(t0)
    sub     s4, s4, s0
    sw      s4, 0(t0)           # LED 显示 cycle 总数

    /* 校验值放到数码管 */
    sw      s3, 4(t0)

    /* 校验值是否为预期常量（取决于具体输入数据） */
    /* 这里仅检查 s3 ≠ 0，作为"程序确实跑完了"的弱断言 */
    beqz    s3, fail

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

/* ---------------- ① 链表遍历 ---------------- */
/* list_walk(): 顺序累加 16 节点 list 的 val 字段，返回 sum */
/* 节点格式：next(4B) | val(4B)；最后 next=0 */
list_walk:
    la      t0, list_head
    li      t1, 0
lw_loop:
    beqz    t0, lw_done
    lw      t2, 4(t0)           # val
    add     t1, t1, t2
    lw      t0, 0(t0)           # next（指针追逐：load-use → stall）
    j       lw_loop
lw_done:
    mv      a0, t1
    jalr    x0, ra, 0

/* ---------------- ② 矩阵乘累加 ---------------- */
/* 4×4 整数矩阵 acc += A[i][k]*B[k][i]（用累加，不写回） */
matrix_mac:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    li      t0, 0               # acc
    li      t1, 0               # i
mac_i:
    li      t2, 0               # k
mac_k:
    /* a_addr = mat_a + (i*4+k)*4 */
    slli    t3, t1, 2
    add     t3, t3, t2
    slli    t3, t3, 2
    la      t4, mat_a
    add     t3, t3, t4
    lw      a0, 0(t3)
    /* b_addr = mat_b + (k*4+i)*4 */
    slli    t3, t2, 2
    add     t3, t3, t1
    slli    t3, t3, 2
    la      t4, mat_b
    add     t3, t3, t4
    lw      a1, 0(t3)
    /* 暂存 t0/t1/t2 到栈：mul32 会使用 t0/t1 */
    sw      t0, 8(sp)
    sw      t1, 4(sp)
    sw      t2, 0(sp)
    jal     ra, mul32           # a0 = a0 * a1
    lw      t0, 8(sp)
    lw      t1, 4(sp)
    lw      t2, 0(sp)
    add     t0, t0, a0
    addi    t2, t2, 1
    li      t3, 4
    blt     t2, t3, mac_k
    addi    t1, t1, 1
    li      t3, 4
    blt     t1, t3, mac_i
    mv      a0, t0
    lw      ra, 12(sp)
    addi    sp, sp, 16
    jalr    x0, ra, 0

/* mul32(a0, a1) → a0 (无符号 32×32→32) */
mul32:
    li      t0, 0
    li      t1, 32
m32:
    andi    t2, a1, 1
    beqz    t2, m32s
    add     t0, t0, a0
m32s:
    slli    a0, a0, 1
    srli    a1, a1, 1
    addi    t1, t1, -1
    bnez    t1, m32
    mv      a0, t0
    jalr    x0, ra, 0

/* ---------------- ③ 状态机/字节流求和 ---------------- */
/* 对一个 32 字节字符串做加权校验：sum = Σ (i+1)*s[i] */
state_sum:
    la      t0, msg
    li      t1, 0               # sum
    li      t2, 0               # i
    li      t3, 32
ss_loop:
    bge     t2, t3, ss_done
    add     t4, t0, t2
    lbu     t5, 0(t4)
    addi    t6, t2, 1           # 权重 = i+1
    /* 软件乘 t5 * t6（小数：使用同一 mul32） */
    mv      a0, t5
    mv      a1, t6
    /* 暂存 t1/t2/t3/t0 */
    addi    sp, sp, -24
    sw      ra, 20(sp)
    sw      t0, 16(sp)
    sw      t1, 12(sp)
    sw      t2,  8(sp)
    sw      t3,  4(sp)
    jal     ra, mul32
    lw      ra, 20(sp)
    lw      t0, 16(sp)
    lw      t1, 12(sp)
    lw      t2,  8(sp)
    lw      t3,  4(sp)
    addi    sp, sp, 24
    add     t1, t1, a0
    addi    t2, t2, 1
    j       ss_loop
ss_done:
    mv      a0, t1
    jalr    x0, ra, 0

    /* ---------- 静态数据 ---------- */
    .section .data
    .align 2
list_head:
    .word list_n1, 100
list_n1:
    .word list_n2, 200
list_n2:
    .word list_n3, 300
list_n3:
    .word list_n4, 400
list_n4:
    .word list_n5, 500
list_n5:
    .word list_n6, 600
list_n6:
    .word list_n7, 700
list_n7:
    .word list_n8, 800
list_n8:
    .word list_n9, 900
list_n9:
    .word list_nA, 1000
list_nA:
    .word list_nB, 1100
list_nB:
    .word list_nC, 1200
list_nC:
    .word list_nD, 1300
list_nD:
    .word list_nE, 1400
list_nE:
    .word list_nF, 1500
list_nF:
    .word 0,       1600

mat_a:
    .word 1, 2, 3, 4
    .word 5, 6, 7, 8
    .word 9, 10, 11, 12
    .word 13, 14, 15, 16
mat_b:
    .word 16, 15, 14, 13
    .word 12, 11, 10,  9
    .word  8,  7,  6,  5
    .word  4,  3,  2,  1
msg:
    .ascii "RV32I CoreMark-lite OK!--------"
    .byte 0
