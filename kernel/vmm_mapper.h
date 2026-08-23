#ifndef VMM_MAPPER_H
#define VMM_MAPPER_H

#include <stdbool.h>
#include <stdint.h>

struct pmm_allocator;

/* Evidence returned only after one complete 4 KiB mapping is published. */
struct vmm_map_result {
    uint64_t *pte;
    uint64_t allocated_table_count;
};

/*
 * Map one aligned virtual page in an existing address-space root.
 *
 * Existing parent tables are reused. Missing parent tables are allocated from
 * allocator, cleared through the HHDM, linked, and only then made PRESENT.
 * The target data frame is owned by the caller and is never allocated here.
 */
bool vmm_map_page_4k(struct pmm_allocator *allocator,
                     uint64_t root_physical_address,
                     uint64_t hhdm_offset,
                     uint64_t virtual_address,
                     uint64_t physical_address,
                     struct vmm_map_result *result);

#endif
