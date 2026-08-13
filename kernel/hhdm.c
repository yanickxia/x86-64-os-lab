#include "hhdm.h"

#include <stddef.h>

#include "pmm.h"

bool hhdm_prepare_page(uint64_t hhdm_offset, uint64_t physical_address, uint64_t **virtual_page) {
    /*
     * Lesson 27 HHDM page-preparation contract:
     * 1. Reject a NULL output pointer, a non-page-aligned PA, and addition
     *    overflow in hhdm_offset + physical_address.
     * 2. Convert PA to VA with Limine's HHDM offset.
     * 3. Treat the 4 KiB page as 512 uint64_t words and clear every word.
     * 4. Publish the resulting pointer through virtual_page and return true.
     *
     * Do not hard-code QEMU's observed HHDM offset.
     */
    if (virtual_page == NULL) {
        return false;
    }

    if (physical_address % 4096 != 0) {
        return false;
    }

    if (physical_address > UINT64_MAX - hhdm_offset) {
        return false;
    }

    uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);

    for (size_t index = 0; index < PMM_PAGE_SIZE / sizeof(*page); ++index) {
        page[index] = 0;
    }

    *virtual_page = page;
    return true;
}
