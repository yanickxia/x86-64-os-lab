#include "faults.h"

#include <stddef.h>

bool page_fault_decode(uint64_t address, uint64_t error_code, uint64_t rip, struct page_fault_report *report) {
    /*
     * RED / TODO (lesson 28): turn the CPU's raw #PF evidence into a report.
     *
     * 1. Reject report == NULL.
     * 2. Preserve address, error_code, and rip exactly.
     * 3. Decode bits 0..4 with the PAGE_FAULT_* masks from faults.h.
     *
     * Keep this function pure: it does not print, halt, read CR2, or repair a
     * page table. The assembly/handler bridge performs those architecture
     * duties before this policy-free decoder is called.
     */
    if (report == NULL) {
        return false;
    }

    report->address = address;
    report->rip = rip;
    report->error_code = error_code;

    bool fault_present = (error_code & PAGE_FAULT_PRESENT) != 0;
    bool fault_write = (error_code & PAGE_FAULT_WRITE) != 0;
    bool fault_user = (error_code & PAGE_FAULT_USER) != 0;
    bool fault_reserved_write = (error_code & PAGE_FAULT_RESERVED_WRITE) != 0;
    bool fault_instruction_fetch = (error_code & PAGE_FAULT_INSTRUCTION_FETCH) != 0;

    report->present = fault_present;
    report->write = fault_write;
    report->user = fault_user;
    report->reserved_write = fault_reserved_write;
    report->instruction_fetch = fault_instruction_fetch;

    return true;
}
