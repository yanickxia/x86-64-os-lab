#ifndef VMM_H
#define VMM_H

#include <stdbool.h>
#include <stdint.h>

#define VMM_PAGE_SIZE UINT64_C(4096)
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

bool vmm_map_single_4k(struct vmm_page_table_path *path, uint64_t virtual_address, uint64_t physical_address);

#endif
