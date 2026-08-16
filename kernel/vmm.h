#ifndef VMM_H
#define VMM_H

#include <stdbool.h>
#include <stdint.h>

#define VMM_PAGE_SIZE UINT64_C(4096)
#define VMM_ENTRY_COUNT UINT64_C(512)
#define VMM_INDEX_MASK UINT64_C(0x1ff)
#define VMM_PAGE_ADDRESS_MASK UINT64_C(0x000ffffffffff000)

#define VMM_PAGE_PRESENT UINT64_C(1)
#define VMM_PAGE_WRITABLE (UINT64_C(1) << 1)

#define VMM_PML4_INDEX(address) (((address) >> 39) & VMM_INDEX_MASK)
#define VMM_PDPT_INDEX(address) (((address) >> 30) & VMM_INDEX_MASK)
#define VMM_PD_INDEX(address) (((address) >> 21) & VMM_INDEX_MASK)
#define VMM_PT_INDEX(address) (((address) >> 12) & VMM_INDEX_MASK)

/*
 * One already-allocated and already-cleared four-level path. The *_pa fields
 * are encoded into paging entries; the pointer fields are HHDM aliases used
 * by C while constructing those entries.
 */
struct vmm_page_table_path {
    uint64_t pml4_pa;
    uint64_t pdpt_pa;
    uint64_t pd_pa;
    uint64_t pt_pa;
    uint64_t *pml4;
    uint64_t *pdpt;
    uint64_t *pd;
    uint64_t *pt;
};

struct page_fault_report;

bool vmm_map_single_4k(struct vmm_page_table_path *path, uint64_t virtual_address, uint64_t physical_address);

/*
 * Bootstrap a new root from the currently active root while retaining the
 * destination entry that owns the lesson-29 mapping path.
 */
bool vmm_clone_root_preserving_entry(uint64_t *destination, const uint64_t *source, uint64_t preserved_index);

/*
 * Resolve one deliberately narrow demand-mapping policy: a non-present,
 * supervisor data write may claim one pre-reserved frame through an empty PTE.
 */
bool vmm_resolve_demand_write(const struct page_fault_report *report,
                              uint64_t expected_virtual_page,
                              uint64_t physical_address,
                              uint64_t *pte);

#endif
