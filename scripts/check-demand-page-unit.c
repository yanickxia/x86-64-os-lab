#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "faults.h"
#include "vmm.h"

static struct page_fault_report eligible_report(uint64_t address) {
    return (struct page_fault_report){
        .address = address,
        .error_code = PAGE_FAULT_WRITE,
        .rip = UINT64_C(0xffffffff80001234),
        .present = false,
        .write = true,
        .user = false,
        .reserved_write = false,
        .instruction_fetch = false,
    };
}

static bool rejected_without_mutation(const struct page_fault_report *report,
                                      uint64_t virtual_page,
                                      uint64_t physical_address,
                                      uint64_t initial_pte) {
    uint64_t pte = initial_pte;
    return !vmm_resolve_demand_write(report, virtual_page, physical_address, &pte) && pte == initial_pte;
}

int main(void) {
    const uint64_t virtual_page = UINT64_C(0x000012345678a000);
    const uint64_t physical_page = UINT64_C(0x5000);
    struct page_fault_report report = eligible_report(virtual_page + UINT64_C(0x38));
    uint64_t pte = 0;

    if (!vmm_resolve_demand_write(&report, virtual_page, physical_page, &pte) ||
        pte != (physical_page | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE)) {
        fputs("eligible non-present supervisor write was not mapped\n", stderr);
        return 1;
    }

    pte = 0;
    if (!vmm_resolve_demand_write(&report, virtual_page, 0, &pte) ||
        pte != (VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE)) {
        fputs("physical frame zero must remain a valid mapping target\n", stderr);
        return 1;
    }

    if (!rejected_without_mutation(NULL, virtual_page, physical_page, 0) ||
        !rejected_without_mutation(&report, virtual_page + 1, physical_page, 0) ||
        !rejected_without_mutation(&report, virtual_page, physical_page + 1, 0) ||
        !rejected_without_mutation(&report, virtual_page + VMM_PAGE_SIZE, physical_page, 0) ||
        !rejected_without_mutation(&report, virtual_page, physical_page, UINT64_C(0x200)) ||
        vmm_resolve_demand_write(&report, virtual_page, physical_page, NULL)) {
        fputs("invalid input was accepted or changed the destination PTE\n", stderr);
        return 1;
    }

    struct page_fault_report invalid = report;
    invalid.present = true;
    invalid.error_code |= PAGE_FAULT_PRESENT;
    if (!rejected_without_mutation(&invalid, virtual_page, physical_page, 0)) {
        fputs("a protection fault was accepted as a demand miss\n", stderr);
        return 1;
    }

    invalid = report;
    invalid.write = false;
    invalid.error_code = 0;
    if (!rejected_without_mutation(&invalid, virtual_page, physical_page, 0)) {
        fputs("a read fault was accepted as a demand write\n", stderr);
        return 1;
    }

    invalid = report;
    invalid.user = true;
    invalid.error_code |= PAGE_FAULT_USER;
    if (!rejected_without_mutation(&invalid, virtual_page, physical_page, 0)) {
        fputs("a user fault was accepted by the supervisor-only policy\n", stderr);
        return 1;
    }

    invalid = report;
    invalid.reserved_write = true;
    invalid.error_code |= PAGE_FAULT_RESERVED_WRITE;
    if (!rejected_without_mutation(&invalid, virtual_page, physical_page, 0)) {
        fputs("a reserved-bit violation was accepted as a demand miss\n", stderr);
        return 1;
    }

    invalid = report;
    invalid.instruction_fetch = true;
    invalid.error_code |= PAGE_FAULT_INSTRUCTION_FETCH;
    if (!rejected_without_mutation(&invalid, virtual_page, physical_page, 0)) {
        fputs("an instruction-fetch fault was accepted as a data write\n", stderr);
        return 1;
    }

    puts("demand-page pure-C checks passed");
    return 0;
}
