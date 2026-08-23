#include "vmm.h"

#include <stddef.h>

#include "faults.h"

bool vmm_map_single_4k(struct vmm_page_table_path *path, uint64_t virtual_address, uint64_t physical_address) {
    /*
     * Lesson 29 contract: connect one already-cleared four-level path.
     *
     * 1. Reject NULL table pointers and non-page-aligned physical addresses.
     * 2. Select one entry at each level with the VMM_*_INDEX macros.
     * 3. Parent entries contain the next table's PA | PRESENT | WRITABLE.
     * 4. The leaf PTE contains physical_address | PRESENT | WRITABLE.
     *
     * Do not put an HHDM virtual pointer into a paging entry and do not load
     * CR3 here. Allocation, HHDM conversion, clearing and activation belong to
     * separate layers of the lesson scaffold.
     */
    if (path == NULL || path->pml4 == NULL || path->pt == NULL || path->pd == NULL || path->pdpt == NULL) {
        return false;
    }

    if ((path->pml4_pa & ~VMM_PAGE_ADDRESS_MASK) != 0 || (path->pdpt_pa & ~VMM_PAGE_ADDRESS_MASK) != 0 ||
        (path->pd_pa & ~VMM_PAGE_ADDRESS_MASK) != 0 || (path->pt_pa & ~VMM_PAGE_ADDRESS_MASK) != 0 ||
        (physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0 || (virtual_address & (VMM_PAGE_SIZE - 1)) != 0) {
        return false;
    }

    const uint64_t flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
    path->pml4[VMM_PML4_INDEX(virtual_address)] = path->pdpt_pa | flags;
    path->pdpt[VMM_PDPT_INDEX(virtual_address)] = path->pd_pa | flags;
    path->pd[VMM_PD_INDEX(virtual_address)] = path->pt_pa | flags;
    path->pt[VMM_PT_INDEX(virtual_address)] = physical_address | flags;

    return true;
}

bool vmm_clone_root_preserving_entry(uint64_t *destination, const uint64_t *source, uint64_t preserved_index) {
    /*
     * Lesson 30 contract: copy the active PML4 into the new root without
     * overwriting the destination slot that already owns our custom path.
     *
     * Reject NULL, an in-place copy, and an index outside one 512-entry PML4.
     * This helper only copies root entries; loading CR3 remains an x86 bridge
     * supplied by the lesson scaffold.
     */

    if (destination == NULL || source == NULL || destination == source || preserved_index >= VMM_ENTRY_COUNT) {
        return false;
    }

    for (size_t i = 0; i < VMM_ENTRY_COUNT; i++) {
        if (preserved_index != i) {
            destination[i] = source[i];
        }
    }

    return true;
}

bool vmm_resolve_demand_write(const struct page_fault_report *report, uint64_t expected_virtual_page, uint64_t physical_address,
                              uint64_t *pte) {
    /*
     * Lesson 31 contract: publish physical_address | PRESENT | WRITABLE
     * only when this is the expected non-present supervisor write and the
     * destination PTE is still empty. All invalid inputs must leave *pte
     * unchanged. The interrupt return and TLB invalidation live elsewhere.
     */
    if (report == NULL || pte == NULL || (expected_virtual_page & (VMM_PAGE_SIZE - 1)) != 0 ||
        (physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0) {
        return false;
    }

    if (*pte != 0) {
        return false;
    }

    const uint64_t fault_page = report->address & ~(VMM_PAGE_SIZE - 1);

    if (fault_page != expected_virtual_page) {
        return false;
    }

    if (report->error_code != PAGE_FAULT_WRITE) {
        return false;
    }

    *pte = physical_address | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;

    return true;
}

bool vmm_walk_to_pte(uint64_t root_physical_address, uint64_t hhdm_offset, uint64_t virtual_address, uint64_t **pte) {
    /*
     * Lesson 32 contract: mirror the CPU's four-level index path in software.
     * Parent entries must be PRESENT and must describe another table rather
     * than a huge leaf. Convert each next-table PA through the supplied HHDM
     * offset, and publish &pt[VMM_PT_INDEX(virtual_address)].
     *
     * Reaching the PT is success even when the leaf PTE itself is zero. Do
     * not allocate, modify entries, invalidate the TLB, or publish *pte on a
     * failed walk.
     */
    if (pte == NULL) {
        return false;
    }

    if ((root_physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0) {
        return false;
    }

    if (root_physical_address > UINT64_MAX - hhdm_offset) {
        return false;
    }

    uint64_t *table = (uint64_t *)(uintptr_t)(hhdm_offset + root_physical_address);
    uint64_t entry = table[VMM_PML4_INDEX(virtual_address)];
    if ((entry & VMM_PAGE_PRESENT) == 0 || (entry & VMM_PAGE_HUGE) != 0) {
        return false;
    }

    uint64_t next_table_pa = entry & VMM_PAGE_ADDRESS_MASK;
    if (next_table_pa > UINT64_MAX - hhdm_offset) {
        return false;
    }
    table = (uint64_t *)(uintptr_t)(hhdm_offset + next_table_pa);
    entry = table[VMM_PDPT_INDEX(virtual_address)];
    if ((entry & VMM_PAGE_PRESENT) == 0 || (entry & VMM_PAGE_HUGE) != 0) {
        return false;
    }

    next_table_pa = entry & VMM_PAGE_ADDRESS_MASK;
    if (next_table_pa > UINT64_MAX - hhdm_offset) {
        return false;
    }
    table = (uint64_t *)(uintptr_t)(hhdm_offset + next_table_pa);
    entry = table[VMM_PD_INDEX(virtual_address)];
    if ((entry & VMM_PAGE_PRESENT) == 0 || (entry & VMM_PAGE_HUGE) != 0) {
        return false;
    }

    next_table_pa = entry & VMM_PAGE_ADDRESS_MASK;
    if (next_table_pa > UINT64_MAX - hhdm_offset) {
        return false;
    }
    table = (uint64_t *)(uintptr_t)(hhdm_offset + next_table_pa);

    *pte = &table[VMM_PT_INDEX(virtual_address)];
    return true;
}
