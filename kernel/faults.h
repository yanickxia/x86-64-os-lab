#ifndef FAULTS_H
#define FAULTS_H

#include <stdbool.h>
#include <stdint.h>

#define PAGE_FAULT_PRESENT UINT64_C(1)
#define PAGE_FAULT_WRITE (UINT64_C(1) << 1)
#define PAGE_FAULT_USER (UINT64_C(1) << 2)
#define PAGE_FAULT_RESERVED_WRITE (UINT64_C(1) << 3)
#define PAGE_FAULT_INSTRUCTION_FETCH (UINT64_C(1) << 4)
#define PAGE_FAULT_PROTECTION_KEY (UINT64_C(1) << 5)
#define PAGE_FAULT_SHADOW_STACK (UINT64_C(1) << 6)

struct interrupt_frame {
    uint64_t rip;
    uint64_t cs;
    uint64_t rflags;
    uint64_t rsp;
    uint64_t ss;
};

struct page_fault_report {
    uint64_t address;
    uint64_t error_code;
    uint64_t rip;
    bool present;
    bool write;
    bool user;
    bool reserved_write;
    bool instruction_fetch;
};

bool page_fault_decode(uint64_t address, uint64_t error_code, uint64_t rip, struct page_fault_report *report);
void page_fault_handler(uint64_t error_code, const struct interrupt_frame *frame) __attribute__((noreturn));

#endif
