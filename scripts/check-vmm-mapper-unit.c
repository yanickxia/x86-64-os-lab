#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "hhdm.h"
#include "pmm.h"
#include "vmm.h"
#include "vmm_mapper.h"

#define TARGET_VA UINT64_C(0x000012b456789000)
#define DATA_PA UINT64_C(0xd000)
#define TABLE_COUNT 16

_Alignas(4096) static uint64_t tables[TABLE_COUNT][VMM_ENTRY_COUNT];
static uint64_t mock_next_pa;
static uint64_t mock_success_count;
static uint64_t mock_fail_after;

bool pmm_alloc_page(struct pmm_allocator *allocator, uint64_t *physical_address) {
    if (allocator == NULL || physical_address == NULL || allocator->free_pages == 0 ||
        mock_success_count == mock_fail_after || mock_next_pa / PMM_PAGE_SIZE >= TABLE_COUNT) {
        return false;
    }

    *physical_address = mock_next_pa;
    mock_next_pa += PMM_PAGE_SIZE;
    mock_success_count++;
    allocator->free_pages--;
    allocator->allocated_pages++;
    return true;
}

bool hhdm_prepare_page(uint64_t hhdm_offset, uint64_t physical_address, uint64_t **virtual_page) {
    if (virtual_page == NULL || (physical_address & (PMM_PAGE_SIZE - 1)) != 0 ||
        physical_address / PMM_PAGE_SIZE >= TABLE_COUNT || physical_address > UINT64_MAX - hhdm_offset) {
        return false;
    }

    uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);
    memset(page, 0, PMM_PAGE_SIZE);
    *virtual_page = page;
    return true;
}

static struct pmm_allocator reset_state(void) {
    memset(tables, 0xa5, sizeof(tables));
    memset(tables[0], 0, PMM_PAGE_SIZE);
    mock_next_pa = PMM_PAGE_SIZE;
    mock_success_count = 0;
    mock_fail_after = UINT64_MAX;

    return (struct pmm_allocator){
        .memory_map = NULL,
        .next_entry_index = 0,
        .next_page = 0,
        .current_range_end = 0,
        .free_pages = TABLE_COUNT - 1,
        .allocated_pages = 0,
    };
}

static bool result_unchanged(const struct vmm_map_result *result) {
    return result->pte == (uint64_t *)(uintptr_t)UINT64_C(0x1234) &&
           result->allocated_table_count == UINT64_C(0x55);
}

static struct vmm_map_result sentinel_result(void) {
    return (struct vmm_map_result){
        .pte = (uint64_t *)(uintptr_t)UINT64_C(0x1234),
        .allocated_table_count = UINT64_C(0x55),
    };
}

int main(void) {
    const uint64_t hhdm_offset = (uint64_t)(uintptr_t)&tables[0][0];
    const uint64_t flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
    struct pmm_allocator allocator = reset_state();
    struct vmm_map_result result = sentinel_result();

    if (!vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        result.allocated_table_count != 3 || result.pte != &tables[3][VMM_PT_INDEX(TARGET_VA)] ||
        tables[0][VMM_PML4_INDEX(TARGET_VA)] != (UINT64_C(0x1000) | flags) ||
        tables[1][VMM_PDPT_INDEX(TARGET_VA)] != (UINT64_C(0x2000) | flags) ||
        tables[2][VMM_PD_INDEX(TARGET_VA)] != (UINT64_C(0x3000) | flags) || *result.pte != (DATA_PA | flags)) {
        fputs("vmm mapper validation: a fully missing parent path was not created\n", stderr);
        return 1;
    }

    const uint64_t adjacent_va = TARGET_VA + VMM_PAGE_SIZE;
    const uint64_t free_before_reuse = allocator.free_pages;
    result = sentinel_result();
    if (!vmm_map_page_4k(&allocator, 0, hhdm_offset, adjacent_va, DATA_PA + VMM_PAGE_SIZE, &result) ||
        result.allocated_table_count != 0 || result.pte != &tables[3][VMM_PT_INDEX(adjacent_va)] ||
        *result.pte != ((DATA_PA + VMM_PAGE_SIZE) | flags) || allocator.free_pages != free_before_reuse) {
        fputs("vmm mapper validation: an existing parent path was not reused\n", stderr);
        return 1;
    }

    result = sentinel_result();
    const uint64_t occupied_pte = tables[3][VMM_PT_INDEX(TARGET_VA)];
    if (vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA + 2 * VMM_PAGE_SIZE, &result) ||
        !result_unchanged(&result) || tables[3][VMM_PT_INDEX(TARGET_VA)] != occupied_pte) {
        fputs("vmm mapper validation: an occupied leaf was overwritten\n", stderr);
        return 1;
    }

    allocator = reset_state();
    memset(tables[1], 0, PMM_PAGE_SIZE);
    memset(tables[2], 0, PMM_PAGE_SIZE);
    tables[0][VMM_PML4_INDEX(TARGET_VA)] = UINT64_C(0x1000) | flags;
    tables[1][VMM_PDPT_INDEX(TARGET_VA)] = UINT64_C(0x2000) | flags;
    mock_next_pa = UINT64_C(0x3000);
    result = sentinel_result();
    if (!vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        result.allocated_table_count != 1 || result.pte != &tables[3][VMM_PT_INDEX(TARGET_VA)] ||
        tables[2][VMM_PD_INDEX(TARGET_VA)] != (UINT64_C(0x3000) | flags)) {
        fputs("vmm mapper validation: a partially existing path did not allocate exactly one table\n", stderr);
        return 1;
    }

    allocator = reset_state();
    memset(tables[1], 0, PMM_PAGE_SIZE);
    tables[0][VMM_PML4_INDEX(TARGET_VA)] = UINT64_C(0x1000) | flags;
    tables[1][VMM_PDPT_INDEX(TARGET_VA)] = UINT64_C(0x2000) | flags | VMM_PAGE_HUGE;
    result = sentinel_result();
    if (vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        !result_unchanged(&result) || allocator.allocated_pages != 0) {
        fputs("vmm mapper validation: a huge parent leaf was treated as a table\n", stderr);
        return 1;
    }

    allocator = reset_state();
    tables[0][VMM_PML4_INDEX(TARGET_VA)] = UINT64_C(0x1000) | VMM_PAGE_PRESENT;
    result = sentinel_result();
    if (vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        !result_unchanged(&result) || allocator.allocated_pages != 0) {
        fputs("vmm mapper validation: a read-only parent was reused for a writable mapping\n", stderr);
        return 1;
    }

    allocator = reset_state();
    mock_fail_after = 1;
    result = sentinel_result();
    if (vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        !result_unchanged(&result) || tables[0][VMM_PML4_INDEX(TARGET_VA)] != 0) {
        fputs("vmm mapper validation: a partial allocation published an incomplete parent path\n", stderr);
        return 1;
    }

    allocator = reset_state();
    result = sentinel_result();
    if (vmm_map_page_4k(NULL, 0, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        vmm_map_page_4k(&allocator, 1, hhdm_offset, TARGET_VA, DATA_PA, &result) ||
        vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA + 1, DATA_PA, &result) ||
        vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA + 1, &result) ||
        vmm_map_page_4k(&allocator, 0, hhdm_offset, TARGET_VA, DATA_PA, NULL) || !result_unchanged(&result)) {
        fputs("vmm mapper validation: invalid input was accepted or changed the result\n", stderr);
        return 1;
    }

    puts("vmm mapper pure-C checks passed");
    return 0;
}
