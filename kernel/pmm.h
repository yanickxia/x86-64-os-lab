#ifndef PMM_H
#define PMM_H

#include <stdbool.h>
#include <stdint.h>

#define PMM_PAGE_SIZE UINT64_C(4096)
#define PMM_NO_PAGE UINT64_MAX

struct limine_memmap_response;

/*
 * Lesson 26 starts with a monotonic physical-page allocator:
 *
 *   USABLE in the Limine map -> free_pages -> allocated_pages
 *
 * It returns physical address numbers. It does not map or clear the page, and
 * it deliberately has no free operation yet.
 */
struct pmm_allocator {
    const struct limine_memmap_response *memory_map;
    uint64_t next_entry_index;
    uint64_t next_page;
    uint64_t current_range_end;
    uint64_t free_pages;
    uint64_t allocated_pages;
};

bool pmm_init(struct pmm_allocator *allocator, const struct limine_memmap_response *memory_map);
bool pmm_alloc_page(struct pmm_allocator *allocator, uint64_t *physical_address);

#endif
