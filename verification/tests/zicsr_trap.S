#include "common.S"

TEST_START
    # mstatus reset value and ordinary mscratch read/write.
    csrr t0, mstatus
    CHECK_REG t0, 0x00001800, 201
    li t1, 0x55aa00ff
    csrrw t0, mscratch, t1
    CHECK_REG t0, 0, 202
    csrr t0, mscratch
    CHECK_REG t0, 0x55aa00ff, 203

    li t1, 0x0000f000
    csrrs t0, mscratch, t1
    CHECK_REG t0, 0x55aa00ff, 204
    csrr t0, mscratch
    CHECK_REG t0, 0x55aaf0ff, 205
    li t1, 0x000000f0
    csrrc t0, mscratch, t1
    CHECK_REG t0, 0x55aaf0ff, 206
    csrr t0, mscratch
    CHECK_REG t0, 0x55aaf00f, 207

    csrrwi t0, mscratch, 3
    CHECK_REG t0, 0x55aaf00f, 208
    csrrsi t0, mscratch, 4
    CHECK_REG t0, 3, 209
    csrrci t0, mscratch, 1
    CHECK_REG t0, 7, 210
    csrr t0, mscratch
    CHECK_REG t0, 6, 211

    # Zero source reads but must not write.
    csrrs t0, mscratch, zero
    CHECK_REG t0, 6, 212
    csrrc t0, mscratch, zero
    CHECK_REG t0, 6, 213

    # Unimplemented CSR reads as zero and ignores writes.
    csrr t0, 0x999
    CHECK_REG t0, 0, 214
    li t1, -1
    csrw 0x999, t1
    csrr t0, 0x999
    CHECK_REG t0, 0, 215

    # mepc writes clear the low two bits.
    li t1, 0x80000123
    csrw mepc, t1
    csrr t0, mepc
    CHECK_REG t0, 0x80000120, 216

    # Minimal M-mode trap flow. mtvec target low bits are ignored on entry.
    la t0, trap_handler
    ori t0, t0, 3
    csrw mtvec, t0
    csrsi mstatus, 8
.Lecall_pc:
    ecall
.Lafter_ecall:
    csrr t0, mepc
    la t1, .Lafter_ecall
    CHECK_EQ t0, t1, 217
    csrr t0, mstatus
    andi t1, t0, 0x88
    CHECK_REG t1, 0x88, 218
    j test_pass

    .align 4
trap_handler:
    csrr t0, mcause
    CHECK_REG t0, 11, 219
    csrr t0, mepc
    la t1, .Lecall_pc
    CHECK_EQ t0, t1, 220
    csrr t0, mstatus
    andi t1, t0, 0x88
    CHECK_REG t1, 0x80, 221
    addi t0, t0, 0
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    mret

TEST_END
