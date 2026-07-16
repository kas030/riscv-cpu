OUTPUT_ARCH(riscv)
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
        KEEP(*(.text.init))
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > IROM

    .data ORIGIN(BRAM) : ALIGN(4)
    {
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.signature .signature.*)
        *(.bss .bss.* COMMON)
    } > BRAM

    /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}

ASSERT(SIZEOF(.text) <= LENGTH(IROM), "IROM image exceeds 16 KiB")
ASSERT(SIZEOF(.data) <= LENGTH(BRAM), "BRAM image exceeds 256 KiB")
