#include "interrupts.h"

struct idt_gate {
    uint16_t offset_low;
    uint16_t selector;
    uint8_t ist;
    uint8_t type_attributes;
    uint16_t offset_middle;
    uint32_t offset_high;
    uint32_t reserved;
} __attribute__((packed));

extern struct idt_gate lesson_idt[7];
extern void isr_invalid_opcode(void);
extern void load_lesson_idt(void);
extern void exception_red_hang(void) __attribute__((noreturn));

void idt_install(void) {
    const uintptr_t handler = (uintptr_t)isr_invalid_opcode;

    lesson_idt[6] = (struct idt_gate){
        .offset_low = (uint16_t)handler,
        .selector = 0x18,
        .ist = 0,
        .type_attributes = 0x8e,
        .offset_middle = (uint16_t)(handler >> 16),
        .offset_high = (uint32_t)(handler >> 32),
        .reserved = 0,
    };

    load_lesson_idt();
}

void invalid_opcode_handler(struct exception_frame *frame) {
    debug_putc('U');

    const uint64_t fault_rip = frame->rip;
    uint64_t resume_rip = fault_rip;
    /*
     * trigger_invalid_opcode() in kernel/payload.asm executed a two-byte UD2.
     * For #UD, fault_rip still points at UD2. Set resume_rip to the address of
     * the following RET; do not edit frame->rip directly here.
     * RED / TODO (lesson 19): advance resume_rip past UD2.
     */

    resume_rip += 2;

    /* A stable red-light guard: unchanged means the recovery policy is absent. */
    if (resume_rip == fault_rip) {
        exception_red_hang();
    }
    frame->rip = resume_rip;
}
