#include "boot_info.h"
#include "interrupts.h"

#define BOOT_INFO_ACK_VALUE UINT64_C(0x214b4f4330323845) /* bytes "E820COK!" */

static void acknowledge_boot_info(const struct boot_info *info) {
    if (info == 0
        || info->magic != BOOT_INFO_MAGIC
        || info->version != BOOT_INFO_VERSION
        || info->entry_size != sizeof(struct e820_entry)
        || info->entry_count == 0
        || info->entry_count > info->entry_capacity
        || info->entry_capacity > BOOT_INFO_MAX_ENTRIES
        || info->entries_phys != BOOT_INFO_ENTRIES_ADDR) {
        return;
    }

    const struct e820_entry *entries = (const struct e820_entry *)(uintptr_t)info->entries_phys;
    for (uint32_t index = 0; index < info->entry_count; index++) {
        if (entries[index].type == E820_TYPE_USABLE && entries[index].length != 0) {
            *(volatile uint64_t *)(uintptr_t)BOOT_INFO_ACK_ADDR = BOOT_INFO_ACK_VALUE;
            return;
        }
    }
}

void kernel_main(const struct boot_info *boot_info) {
    debug_putc('C');
    acknowledge_boot_info(boot_info);
    idt_install();
    trigger_invalid_opcode();
    debug_putc('R');
}
