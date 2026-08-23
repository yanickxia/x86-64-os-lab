#include "vmm_mapper.h"

#include <stddef.h>

#include "hhdm.h"
#include "pmm.h"
#include "vmm.h"

bool vmm_map_page_4k(struct pmm_allocator *allocator,
                     uint64_t root_physical_address,
                     uint64_t hhdm_offset,
                     uint64_t virtual_address,
                     uint64_t physical_address,
                     struct vmm_map_result *result) {
    /*
     * RED / TODO (lesson 33): reuse every valid parent that already exists.
     * At the first zero parent, allocate and clear all remaining table pages,
     * connect the private child path, install the leaf, and publish the first
     * PRESENT parent last. Reject huge/non-zero non-present parents and an
     * occupied leaf. Do not publish result on failure.
     */
    (void)allocator;
    (void)root_physical_address;
    (void)hhdm_offset;
    (void)virtual_address;
    (void)physical_address;
    (void)result;
    return false;
}
