/* Minimal Zicsr + ecall/mret regression.
 * PASS writes 0xC0DEC0DE to LED(0x8020_0040), FAIL writes 0xDEADBEEF.
 */
    .option norvc
    .section .text.init
    .globl _start
_start:
    /* CSRRS/CSRRC register forms on mcause. */
    li      t0, 0x0000000f
    csrw    mcause, t0
    li      t1, 0x00000005
    csrrc   t2, mcause, t1
    bne     t2, t0, fail
    csrr    t3, mcause
    li      t4, 0x0000000a
    bne     t3, t4, fail

    /* The official Zicsr test also uses mscratch. */
    li      t0, 0x13579BDF
    csrrw   t1, mscratch, t0
    csrr    t2, mscratch
    bne     t2, t0, fail
    li      t3, 0x2468ACE0
    csrrs   t4, mscratch, t3
    bne     t4, t0, fail
    or      t0, t0, t3
    csrr    t2, mscratch
    bne     t2, t0, fail
    li      t3, 0x0000000F
    csrrc   t4, mscratch, t3
    bne     t4, t0, fail
    not     t3, t3
    and     t0, t0, t3
    csrr    t2, mscratch
    bne     t2, t0, fail

    /* Immediate CSR form can set/clear mstatus.MIE(bit3). */
    csrw    mstatus, zero
    csrrsi  zero, mstatus, 8
    csrr    t0, mstatus
    andi    t0, t0, 0x0088
    li      t1, 0x00000008
    bne     t0, t1, fail
    csrrci  zero, mstatus, 8
    csrr    t0, mstatus
    andi    t0, t0, 0x0088
    bne     t0, zero, fail

    /* mtvec must hold the trap handler address. */
    la      t0, trap_handler
    lui     t1, 0x80000
    add     t0, t0, t1
    csrw    mtvec, t0
    csrr    t2, mtvec
    bne     t2, t0, fail

    /* Enter trap with MIE=1, MPIE=0. */
    li      t0, 0x00000008
    csrw    mstatus, t0

ecall_site:
    ecall

after_mret:
    csrr    t0, mstatus
    andi    t0, t0, 0x0088
    li      t1, 0x00000088
    bne     t0, t1, fail
    j       pass

trap_handler:
    csrr    t0, mcause
    li      t1, 11
    bne     t0, t1, fail

    csrr    t0, mepc
    la      t1, ecall_site
    lui     t2, 0x80000
    add     t1, t1, t2
    bne     t0, t1, fail

    csrr    t0, mstatus
    andi    t0, t0, 0x0088
    li      t1, 0x00000080
    bne     t0, t1, fail

    addi    t0, t0, 0
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

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
