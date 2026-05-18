/* RV32I CPU 链接脚本
 *
 * 内存布局（与 IROM/DRAM IP 配置一致）：
 *   - 指令存储器 IROM：0x00000000 起，大小由 IROM IP 决定
 *   - 数据存储器 DRAM：0x80200000 起（与 IROM 中 lui x15,0x80200 一致）
 *   - 外设桥（perip_bridge）：0x80000000-0x801FFFFF（UART/LED/SEG/COUNTER）
 *
 * 程序入口固定在 IROM 起始处，链接时不重定位。
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IROM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
    DRAM (rw) : ORIGIN = 0x80200000, LENGTH = 16K
}

SECTIONS
{
    .text :
    {
        *(.text.init)       /* 入口 _start 必须放第一条 */
        *(.text)
        *(.text.*)
    } > IROM

    .rodata :
    {
        *(.rodata)
        *(.rodata.*)
    } > IROM

    .data : ALIGN(4)
    {
        _data_start = .;
        *(.data)
        *(.data.*)
        _data_end = .;
    } > DRAM

    .bss : ALIGN(4)
    {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        _bss_end = .;
    } > DRAM

    /* 栈顶设在 DRAM 末尾，向下增长 */
    _stack_top = ORIGIN(DRAM) + LENGTH(DRAM);

    /* 测试结果暂存区：DRAM 顶端 256 字节，testbench 会探测此处 */
    _result_addr = ORIGIN(DRAM) + LENGTH(DRAM) - 256;
}
