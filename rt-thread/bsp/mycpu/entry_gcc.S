/* entry_gcc.S —— 复位入口。
 *
 * 复位地址 0x80000000，本段必须位于 IROM 首字（linker.ld 用 KEEP(.text.init)）。
 * 数据段不需要搬移：.data/.rodata 由 BRAM 的 .coe 预装载。
 * 本移植不使用 ecall/trap（libcpu 端口为直接切换），无需设置 mtvec。
 */

    .section .text.init
    .globl _start
_start:
    la   sp, __stack_top
    la   a0, __bss_start
    la   a1, __bss_end
    beq  a0, a1, 2f
1:  sw   zero, 0(a0)
    addi a0, a0, 4
    bltu a0, a1, 1b
2:  call main
3:  j    3b
