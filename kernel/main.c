#include "interrupts.h"

void kernel_main(void) {
    debug_putc('C');
    idt_install();
    trigger_invalid_opcode();
    debug_putc('R');
}
