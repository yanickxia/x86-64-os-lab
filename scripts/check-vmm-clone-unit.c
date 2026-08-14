#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "vmm.h"

#define PRESERVED_INDEX UINT64_C(0x24)
#define PRESERVED_ENTRY UINT64_C(0x0000000000002003)

static uint64_t source[VMM_ENTRY_COUNT];
static uint64_t destination[VMM_ENTRY_COUNT];

static bool expect_rejected(const char *case_name, uint64_t *target, const uint64_t *active, uint64_t index) {
    if (vmm_clone_root_preserving_entry(target, active, index)) {
        fprintf(stderr, "vmm root-clone validation: accepted %s\n", case_name);
        return false;
    }

    return true;
}

int main(void) {
    for (uint64_t index = 0; index < VMM_ENTRY_COUNT; ++index) {
        source[index] = (index << 12) | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
        destination[index] = 0;
    }
    destination[PRESERVED_INDEX] = PRESERVED_ENTRY;

    if (!vmm_clone_root_preserving_entry(destination, source, PRESERVED_INDEX)) {
        fputs("vmm root-clone validation: rejected the valid clone contract\n", stderr);
        return 1;
    }

    for (uint64_t index = 0; index < VMM_ENTRY_COUNT; ++index) {
        const uint64_t expected = index == PRESERVED_INDEX ? PRESERVED_ENTRY : source[index];
        if (destination[index] != expected) {
            fprintf(stderr, "vmm root-clone validation: entry %#llx expected %#llx, got %#llx\n",
                    (unsigned long long)index, (unsigned long long)expected,
                    (unsigned long long)destination[index]);
            return 1;
        }
    }

    bool valid = true;
    valid = expect_rejected("a NULL destination", NULL, source, PRESERVED_INDEX) && valid;
    valid = expect_rejected("a NULL source", destination, NULL, PRESERVED_INDEX) && valid;
    valid = expect_rejected("an in-place clone", destination, destination, PRESERVED_INDEX) && valid;
    valid = expect_rejected("an out-of-range preserved index", destination, source, VMM_ENTRY_COUNT) && valid;

    return valid ? 0 : 1;
}
