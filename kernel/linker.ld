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

        /* Keep the lesson payload inside the single sector loaded by BIOS. */
        . = 0x1ff;
        BYTE(0)
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

    ASSERT(SIZEOF(.text) == 0x200, "kernel payload must remain exactly one sector")
    ASSERT(SIZEOF(.bss) == 0, "lesson 19 does not establish a .bss clearing contract yet")
}
