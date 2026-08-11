#ifndef X86_64_OS_LAB_INTERRUPTS_H
#define X86_64_OS_LAB_INTERRUPTS_H

#include <stdint.h>

struct exception_frame {
    uint64_t rip;
    uint64_t cs;
    uint64_t rflags;
    uint64_t rsp;
    uint64_t ss;
};

void debug_putc(char ch);
void idt_install(void);
void trigger_invalid_opcode(void);

#endif
