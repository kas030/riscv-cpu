/* RT-Thread Nano 3.1.5 mycpu 平台链接脚本。
 *
 * 内存布局（与 IROM/BRAM IP 配置一致）：
 *   - IROM：0x80000000 起 16 KiB，CPU 唯一取指口（pc[13:2]），只放代码；
 *   - BRAM：0x80100000 起 256 KiB，.rodata/.data/.bss/堆/栈；
 *   - 外设桥：0x80200000-0x8020005F（SW/KEY/SEG/LED/COUNTER）。
 *
 * .rodata 放在 BRAM 而非 IROM，把 16 KiB 取指空间全部让给代码；
 * .rodata 位于 BRAM 起始，保证 objcopy 输出（bin/coe）偏移 0 即 BRAM 字 0。
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IROM (rx)  : ORIGIN = 0x80000000, LENGTH = 16K
    BRAM (rwx) : ORIGIN = 0x80100000, LENGTH = 256K
}

SECTIONS
{
    .text ORIGIN(IROM) : ALIGN(4)
    {
        KEEP(*(.text.init))     /* 入口 _start 必须放第一条 */
        *(.text .text.*)
    } > IROM

    .rodata : ALIGN(4)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
    } > BRAM

    .data : ALIGN(4)
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        __data_end = .;
    } > BRAM

    .bss : ALIGN(4)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } > BRAM

    /* 栈顶设在 BRAM 末尾，向下增长；堆覆盖 bss 到栈顶 */
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

ASSERT(SIZEOF(.text) <= LENGTH(IROM), "IROM overflow")
ASSERT(SIZEOF(.rodata) + SIZEOF(.data) + SIZEOF(.bss) <= LENGTH(BRAM), "BRAM overflow")
