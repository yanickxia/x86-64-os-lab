#ifndef HHDM_H
#define HHDM_H

#include <stdbool.h>
#include <stdint.h>

/*
 * Convert one kernel-owned physical frame through Limine's HHDM and prepare
 * its contents for a future kernel data structure.
 *
 * The caller must only pass a 4 KiB frame covered by the HHDM, such as a frame
 * allocated from a LIMINE_MEMMAP_USABLE range.
 */
bool hhdm_prepare_page(uint64_t hhdm_offset, uint64_t physical_address, uint64_t **virtual_page);

#endif
