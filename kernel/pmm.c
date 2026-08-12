#include "pmm.h"

#include <stddef.h>

#include <limine.h>

bool pmm_init(struct pmm_allocator *allocator, const struct limine_memmap_response *memory_map) {
    /*
     * Lesson 26 initialisation contract:
     * 1. Validate allocator, memory_map, entries and entry_count.
     * 2. Initialise every cursor/counter field in allocator.
     * 3. Count only LIMINE_MEMMAP_USABLE pages.
     * 4. Return true only when at least one free 4 KiB page exists.
     *
     * The pinned Limine protocol guarantees USABLE base/length are already
     * 4096-byte aligned, so page_count = entry->length / PMM_PAGE_SIZE.
     */

    if (allocator == NULL || memory_map == NULL || memory_map->entries == NULL || memory_map->entry_count == 0) {
        return false;
    }

    allocator->memory_map = memory_map;
    allocator->next_entry_index = 0;
    allocator->next_page = 0;
    allocator->current_range_end = 0;
    allocator->free_pages = 0;
    allocator->allocated_pages = 0;

    for (uint64_t index = 0; index < memory_map->entry_count; ++index) {
        const struct limine_memmap_entry *entry = memory_map->entries[index];

        if (entry != NULL && entry->type == LIMINE_MEMMAP_USABLE) {
            allocator->free_pages += entry->length / PMM_PAGE_SIZE;
        }
    }

    return allocator->free_pages > 0;
}

bool pmm_alloc_page(struct pmm_allocator *allocator, uint64_t *physical_address) {
    /*
     * Lesson 26 allocation contract:
     * 1. Reject invalid arguments or an exhausted allocator.
     * 2. Starting at next_entry_index, skip NULL and non-USABLE entries.
     * 3. When the current range is exhausted, select the next USABLE range.
     * 4. Return next_page, advance it by PMM_PAGE_SIZE, then move one page
     *    from free_pages to allocated_pages.
     */
    if (allocator == NULL || physical_address == NULL || allocator->memory_map == NULL || allocator->free_pages == 0) {
        return false;
    }

    /* A range is exhausted when its next page reaches the half-open end. */
    while (allocator->next_page >= allocator->current_range_end) {
        const struct limine_memmap_entry *entry = NULL;

        /* Consume map entries once, skipping every range that is not free now. */
        while (allocator->next_entry_index < allocator->memory_map->entry_count) {
            entry = allocator->memory_map->entries[allocator->next_entry_index++];

            if (entry != NULL && entry->type == LIMINE_MEMMAP_USABLE && entry->length >= PMM_PAGE_SIZE) {
                break;
            }

            entry = NULL;
        }

        if (entry == NULL) {
            return false;
        }

        allocator->next_page = entry->base;
        allocator->current_range_end = entry->base + entry->length;
    }

    /* Returning the current cursor transfers exactly one page to the caller. */
    *physical_address = allocator->next_page;
    allocator->next_page += PMM_PAGE_SIZE;
    allocator->free_pages--;
    allocator->allocated_pages++;
    return true;
}
