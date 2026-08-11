#ifndef X86_64_OS_LAB_BOOT_INFO_H
#define X86_64_OS_LAB_BOOT_INFO_H

#include <stddef.h>
#include <stdint.h>

#define BOOT_INFO_ADDR UINT64_C(0x5000)
#define BOOT_INFO_ENTRIES_ADDR UINT64_C(0x5020)
#define BOOT_INFO_ACK_ADDR UINT64_C(0x7010)
#define ELF_ENV_ACK_ADDR UINT64_C(0x7018)
#define BOOT_INFO_MAGIC UINT32_C(0x464e4942)
#define BOOT_INFO_VERSION UINT16_C(1)
#define BOOT_INFO_MAX_ENTRIES UINT32_C(32)
#define E820_TYPE_USABLE UINT32_C(1)

struct e820_entry {
    uint64_t base;
    uint64_t length;
    uint32_t type;
    uint32_t attributes;
};

struct boot_info {
    uint32_t magic;
    uint16_t version;
    uint16_t entry_size;
    uint32_t entry_count;
    uint32_t entry_capacity;
    uint64_t entries_phys;
    uint64_t kernel_entry_phys;
};

_Static_assert(sizeof(struct e820_entry) == 24, "E820 entry layout must match stage 2");
_Static_assert(sizeof(struct boot_info) == 32, "boot_info layout must match stage 2");
_Static_assert(offsetof(struct boot_info, entry_count) == 8, "entry_count offset mismatch");
_Static_assert(offsetof(struct boot_info, entries_phys) == 16, "entries_phys offset mismatch");
_Static_assert(offsetof(struct boot_info, kernel_entry_phys) == 24, "kernel entry offset mismatch");

#endif
