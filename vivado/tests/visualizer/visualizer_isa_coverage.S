/* 可视化器基础 ISA 覆盖微程序。
 * build_images.mjs 生成与下列指令序列等价的固定机器码镜像；该场景用于补齐
 * 常规测试未动态退休的逻辑/移位/比较、jalr 与 csrrwi，并通过重复回访训练
 * 双发射 hint 表。最终 LED 仍使用项目统一 PASS/FAIL 值。
 */
    .section .text.init
    .globl _start
_start:
    addi    t3, zero, 0
dual_loop:
    addi    t3, t3, 1
    addi    t4, zero, 7
    addi    t5, zero, 9
    slti    t6, t3, 3
    bne     t6, zero, dual_loop

    addi    ra, zero, 5
    addi    sp, zero, 2
    sub     gp, ra, sp
    sll     tp, ra, sp
    slt     t0, ra, sp
    sltu    t1, ra, sp
    xor     t2, ra, sp
    srl     s0, ra, sp
    or      s1, ra, sp
    and     a0, ra, sp
    slli    a1, sp, 3
    srli    a2, a1, 2
    addi    a3, zero, -8
    sra     a4, a3, sp
    srai    a5, a3, 2
    slti    a6, a3, 0
    sltiu   a7, a3, 1
    xori    s2, sp, 7
    ori     s3, sp, 8
    andi    s4, s2, 1

    lui     s5, 0x80000
    addi    s5, s5, jalr_target - _start
    jalr    s6, 0(s5)
    j       fail
jalr_target:
    csrrwi  s7, mscratch, 3

pass:
    lui     a0, 0xc0dec
    addi    a0, a0, 0x0de
    jal     zero, done
fail:
    lui     a0, 0xdeadc
    addi    a0, a0, -0x111
done:
    lui     t0, 0x80200
    addi    t0, t0, 0x40
    sw      a0, 0(t0)
1:  jal     zero, 1b
