#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <limine.h>

#include "hhdm.h"
#include "pmm.h"

#define HHDM_POISON UINT64_C(0xa5a55a5adeadbeef)
#define PAGE_WORD_COUNT (PMM_PAGE_SIZE / sizeof(uint64_t))

__attribute__((used, section(".limine_requests_start")))
static volatile uint64_t limine_requests_start[] = LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests")))
static volatile uint64_t limine_base_revision[] = LIMINE_BASE_REVISION(6);

__attribute__((used, section(".limine_requests")))
static volatile struct limine_memmap_request memory_map_request = {
    .id = LIMINE_MEMMAP_REQUEST_ID,
    .revision = 0,
};

__attribute__((used, section(".limine_requests")))
static volatile struct limine_hhdm_request hhdm_request = {
    .id = LIMINE_HHDM_REQUEST_ID,
    .revision = 0,
};

__attribute__((used, section(".limine_requests_end")))
static volatile uint64_t limine_requests_end[] = LIMINE_REQUESTS_END_MARKER;

static void debug_putc(char value) {
    __asm__ volatile("outb %0, $0xe9" : : "a"(value));
}

static void debug_puts(const char *text) {
    while (*text != '\0') {
        debug_putc(*text++);
    }
}

static void debug_hex64(uint64_t value) {
    static const char digits[] = "0123456789abcdef";

    debug_puts("0x");
    for (int shift = 60; shift >= 0; shift -= 4) {
        debug_putc(digits[(value >> shift) & UINT64_C(0xf)]);
    }
}

static bool usable_page_contains(const struct limine_memmap_response *response, uint64_t page) {
    for (uint64_t index = 0; index < response->entry_count; ++index) {
        const struct limine_memmap_entry *entry = response->entries[index];

        if (entry == NULL || entry->type != LIMINE_MEMMAP_USABLE) {
            continue;
        }

        if (page >= entry->base && page - entry->base < entry->length &&
            entry->length - (page - entry->base) >= PMM_PAGE_SIZE) {
            return true;
        }
    }

    return false;
}

/* Observer infrastructure: give every word a non-zero value before the exercise clears it. */
static bool poison_hhdm_page(uint64_t hhdm_offset, uint64_t physical_address) {
    if ((physical_address & (PMM_PAGE_SIZE - 1)) != 0 || physical_address > UINT64_MAX - hhdm_offset) {
        return false;
    }

    uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);
    for (size_t index = 0; index < PAGE_WORD_COUNT; ++index) {
        page[index] = HHDM_POISON;
    }

    return true;
}

static bool page_is_zero(const uint64_t *page) {
    if (page == NULL) {
        return false;
    }

    for (size_t index = 0; index < PAGE_WORD_COUNT; ++index) {
        if (page[index] != 0) {
            return false;
        }
    }

    return true;
}

static bool accept_limine_handoff(void) {
    /*
     * Lesson 25 handoff contract: validate and consume the memory-map response.
     *
     * Hint ladder:
     * 1. Reject an unsupported limine_base_revision before reading a response.
     * 2. Read memory_map_request.response into a local response pointer.
     * 3. Reject NULL and an entry_count of zero before entering the loop.
     * 4. response->entries[index] is a pointer; reject NULL before reading
     *    entry->type and entry->length.
     * 5. Return true after finding one LIMINE_MEMMAP_USABLE entry whose
     *    length can hold at least one 4096-byte page.
     *
     * Run `make inspect-limine-api` to see the official field definitions.
     */
    if (!LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)) {
        return false;
    }

    const struct limine_memmap_response *response = memory_map_request.response;
    if (response == NULL || response->entry_count == 0) {
        return false;
    }

    bool found_usable = false;

    for (size_t i = 0; i < response->entry_count; i++) {
        const struct limine_memmap_entry *entry = response->entries[i];

        if (entry != NULL && entry->type == LIMINE_MEMMAP_USABLE && entry->length >= 4096) {
            found_usable = true;
            break;
        }
    }

    return found_usable;
}

__attribute__((noreturn))
static void halt_forever(void) {
    for (;;) {
        __asm__ volatile("cli; hlt");
    }
}

__attribute__((noreturn))
void limine_kernel_main(void) {
    debug_puts("LIMINE:ENTRY\n");

    if (!accept_limine_handoff()) {
        debug_puts("LIMINE:MEMMAP:FAIL\n");
        halt_forever();
    }

    debug_puts("LIMINE:MEMMAP:OK\n");

    const struct limine_memmap_response *response = memory_map_request.response;
    struct pmm_allocator allocator;

    if (!pmm_init(&allocator, response)) {
        debug_puts("PMM:INIT:FAIL\n");
        halt_forever();
    }

    /* Observer-only snapshot: this is not another field in pmm_allocator. */
    const uint64_t free_before = allocator.free_pages;
    uint64_t first_page = PMM_NO_PAGE;
    uint64_t second_page = PMM_NO_PAGE;

    if (!pmm_alloc_page(&allocator, &first_page) ||
        !pmm_alloc_page(&allocator, &second_page)) {
        debug_puts("PMM:ALLOC:FAIL\n");
        halt_forever();
    }

    debug_puts("PMM:FREE-BEFORE=");
    debug_hex64(free_before);
    debug_putc('\n');
    debug_puts("PMM:FIRST=");
    debug_hex64(first_page);
    debug_putc('\n');
    debug_puts("PMM:SECOND=");
    debug_hex64(second_page);
    debug_putc('\n');
    /* "free after" is allocator.free_pages after two calls, not a separate field. */
    debug_puts("PMM:FREE-AFTER=");
    debug_hex64(allocator.free_pages);
    debug_putc('\n');
    debug_puts("PMM:ALLOCATED=");
    debug_hex64(allocator.allocated_pages);
    debug_putc('\n');

    const bool pmm_state_valid = free_before >= 2 && first_page != second_page &&
                                 (first_page & (PMM_PAGE_SIZE - 1)) == 0 &&
                                 (second_page & (PMM_PAGE_SIZE - 1)) == 0 &&
                                 usable_page_contains(response, first_page) &&
                                 usable_page_contains(response, second_page) &&
                                 allocator.free_pages == free_before - 2 &&
                                 allocator.allocated_pages == 2;

    if (!pmm_state_valid) {
        debug_puts("PMM:STATE:FAIL\n");
        halt_forever();
    }

    debug_puts("PMM:OK\n");

    const struct limine_hhdm_response *hhdm_response = hhdm_request.response;
    if (hhdm_response == NULL) {
        debug_puts("HHDM:RESPONSE:FAIL\n");
        halt_forever();
    }

    debug_puts("HHDM:RESPONSE:OK\n");

    if (!poison_hhdm_page(hhdm_response->offset, first_page)) {
        debug_puts("HHDM:POISON:FAIL\n");
        halt_forever();
    }

    uint64_t *virtual_page = NULL;
    const uint64_t *poisoned_page = (const uint64_t *)(uintptr_t)(hhdm_response->offset + first_page);
    const uint64_t before_first = poisoned_page[0];
    const uint64_t before_last = poisoned_page[PAGE_WORD_COUNT - 1];

    if (!hhdm_prepare_page(hhdm_response->offset, first_page, &virtual_page)) {
        debug_puts("HHDM:PREPARE:FAIL\n");
        halt_forever();
    }

    debug_puts("HHDM:OFFSET=");
    debug_hex64(hhdm_response->offset);
    debug_putc('\n');
    debug_puts("HHDM:PA=");
    debug_hex64(first_page);
    debug_putc('\n');
    debug_puts("HHDM:VA=");
    debug_hex64((uint64_t)(uintptr_t)virtual_page);
    debug_putc('\n');
    debug_puts("HHDM:BEFORE-FIRST=");
    debug_hex64(before_first);
    debug_putc('\n');
    debug_puts("HHDM:BEFORE-LAST=");
    debug_hex64(before_last);
    debug_putc('\n');
    debug_puts("HHDM:AFTER-FIRST=");
    debug_hex64(virtual_page[0]);
    debug_putc('\n');
    debug_puts("HHDM:AFTER-LAST=");
    debug_hex64(virtual_page[PAGE_WORD_COUNT - 1]);
    debug_putc('\n');

    if (before_first == HHDM_POISON && before_last == HHDM_POISON && page_is_zero(virtual_page)) {
        debug_puts("HHDM:PAGE:OK\n");
    } else {
        debug_puts("HHDM:ZERO:FAIL\n");
    }

    halt_forever();
}
