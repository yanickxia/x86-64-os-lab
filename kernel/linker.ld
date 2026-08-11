ENTRY(kernel_start)

PHDRS
{
    payload PT_LOAD FLAGS(7); /* Transitional RWX segment: code + writable teaching IDT. */
    zeroed  PT_LOAD FLAGS(6); /* Writable memory whose file size is zero. */
}

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
    } :payload

    . = ALIGN(0x1000);
    .bss (NOLOAD) :
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __bss_end = .;
    } :zeroed

    /DISCARD/ :
    {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }

    ASSERT(SIZEOF(.text) == KERNEL_IMAGE_BYTES, "kernel payload size must match the loader contract")
    ASSERT(SIZEOF(.bss) > 0, "lesson 23 requires a non-empty zero-fill segment")
}
