/* RV32I CPU 链接脚本
 *
 * 内存布局（与 IROM/BRAM IP 配置一致）：
 *   - 指令存储器 IROM：0x00000000 起，映射到 CPU 视角 0x80000000
 *   - 数据存储器 BRAM：0x80100000 起，当前 IP 有效窗口 256KB
 *   - 外设桥：0x80200000-0x802000FF（SW/KEY/SEG/LED/COUNTER）
 *
 * 程序入口固定在 IROM 起始处，链接时不重定位。
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IROM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
    BRAM (rw) : ORIGIN = 0x80100000, LENGTH = 256K
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
    } > BRAM

    .bss : ALIGN(4)
    {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        _bss_end = .;
    } > BRAM

    /* 栈顶设在 BRAM 末尾，向下增长 */
    _stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    /* 测试结果暂存区：BRAM 顶端 256 字节，testbench 会探测此处 */
    _result_addr = ORIGIN(BRAM) + LENGTH(BRAM) - 256;
}
