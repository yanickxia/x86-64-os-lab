#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "vmm.h"

#define TARGET_VA UINT64_C(0x0000123456789000)
#define TARGET_PA UINT64_C(0x7000)

_Alignas(4096) static uint64_t tables[4][VMM_ENTRY_COUNT];

static void build_path(void) {
    for (uint64_t table = 0; table < 4; ++table) {
        for (uint64_t index = 0; index < VMM_ENTRY_COUNT; ++index) {
            tables[table][index] = 0;
        }
    }

    const uint64_t flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
    tables[0][VMM_PML4_INDEX(TARGET_VA)] = UINT64_C(0x1000) | flags;
    tables[1][VMM_PDPT_INDEX(TARGET_VA)] = UINT64_C(0x2000) | flags;
    tables[2][VMM_PD_INDEX(TARGET_VA)] = UINT64_C(0x3000) | flags;
    tables[3][VMM_PT_INDEX(TARGET_VA)] = TARGET_PA | flags;
}

static bool expect_failure_without_output_change(const char *case_name,
                                                 uint64_t root_pa,
                                                 uint64_t hhdm_offset,
                                                 uint64_t virtual_address) {
    uint64_t *output = (uint64_t *)(uintptr_t)UINT64_C(0x1234);

    if (vmm_walk_to_pte(root_pa, hhdm_offset, virtual_address, &output) ||
        output != (uint64_t *)(uintptr_t)UINT64_C(0x1234)) {
        fprintf(stderr, "page-table walk validation: accepted %s or changed its output\n", case_name);
        return false;
    }

    return true;
}

int main(void) {
    const uint64_t hhdm_offset = (uint64_t)(uintptr_t)&tables[0][0];
    const uint64_t flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
    uint64_t *pte = NULL;

    build_path();
    if (!vmm_walk_to_pte(0, hhdm_offset, TARGET_VA + UINT64_C(0x38), &pte) ||
        pte != &tables[3][VMM_PT_INDEX(TARGET_VA)] || *pte != (TARGET_PA | flags)) {
        fputs("page-table walk validation: mapped leaf was not found\n", stderr);
        return 1;
    }

    pte = NULL;
    if (!vmm_walk_to_pte(0, hhdm_offset, TARGET_VA + VMM_PAGE_SIZE, &pte) ||
        pte != &tables[3][VMM_PT_INDEX(TARGET_VA + VMM_PAGE_SIZE)] || *pte != 0) {
        fputs("page-table walk validation: empty leaf slot was not returned\n", stderr);
        return 1;
    }

    bool valid = true;
    valid = !vmm_walk_to_pte(0, hhdm_offset, TARGET_VA, NULL) && valid;
    valid = expect_failure_without_output_change("an unaligned root PA", 1, hhdm_offset, TARGET_VA) && valid;
    valid = expect_failure_without_output_change("an overflowing HHDM conversion",
                                                 UINT64_C(0x1000),
                                                 UINT64_MAX - UINT64_C(0xfff),
                                                 TARGET_VA) && valid;

    build_path();
    tables[0][VMM_PML4_INDEX(TARGET_VA)] = 0;
    valid = expect_failure_without_output_change("a missing PML4 parent", 0, hhdm_offset, TARGET_VA) && valid;

    build_path();
    tables[1][VMM_PDPT_INDEX(TARGET_VA)] = 0;
    valid = expect_failure_without_output_change("a missing PDPT parent", 0, hhdm_offset, TARGET_VA) && valid;

    build_path();
    tables[2][VMM_PD_INDEX(TARGET_VA)] = 0;
    valid = expect_failure_without_output_change("a missing PD parent", 0, hhdm_offset, TARGET_VA) && valid;

    build_path();
    tables[1][VMM_PDPT_INDEX(TARGET_VA)] |= VMM_PAGE_HUGE;
    valid = expect_failure_without_output_change("a 1 GiB huge-page leaf", 0, hhdm_offset, TARGET_VA) && valid;

    build_path();
    tables[2][VMM_PD_INDEX(TARGET_VA)] |= VMM_PAGE_HUGE;
    valid = expect_failure_without_output_change("a 2 MiB huge-page leaf", 0, hhdm_offset, TARGET_VA) && valid;

    if (!valid) {
        return 1;
    }

    puts("page-table walk pure-C checks passed");
    return 0;
}
