#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <limine.h>

__attribute__((used, section(".limine_requests_start")))
static volatile uint64_t limine_requests_start[] = LIMINE_REQUESTS_START_MARKER;

__attribute__((used, section(".limine_requests")))
static volatile uint64_t limine_base_revision[] = LIMINE_BASE_REVISION(6);

__attribute__((used, section(".limine_requests")))
static volatile struct limine_memmap_request memory_map_request = {
    .id = LIMINE_MEMMAP_REQUEST_ID,
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

    if (accept_limine_handoff()) {
        debug_puts("LIMINE:MEMMAP:OK\n");
    }

    halt_forever();
}
