ENTRY(kernel_start)

SECTIONS
{
    . = 0x00010000;

    .text :
    {
        *(.text)
    }
}
