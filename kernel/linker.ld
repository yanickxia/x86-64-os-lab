ENTRY(kernel_start)

SECTIONS
{
    . = 0x00010000;

    .text :
    {
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)

        /* A tail marker proves that BIOS loaded beyond the first sector. */
        . = KERNEL_IMAGE_BYTES - 8;
        QUAD(0x4345533444414f4c) /* little-endian bytes: "LOAD4SEC" */
    }

    .bss (NOLOAD) :
    {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }

    ASSERT(SIZEOF(.text) == KERNEL_IMAGE_BYTES, "kernel payload size must match the loader contract")
    ASSERT(SIZEOF(.bss) == 0, "bootloader graduation has not established a .bss clearing contract yet")
}
