#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <limine.h>

#include "faults.h"
#include "hhdm.h"
#include "pmm.h"
#include "vmm.h"
#include "vmm_mapper.h"

#define HHDM_POISON UINT64_C(0xa5a55a5adeadbeef)
#define PAGE_WORD_COUNT (PMM_PAGE_SIZE / sizeof(uint64_t))
#define LESSON_PAGE_FAULT_ADDRESS UINT64_C(0x0000400000000000)
#define LESSON_VMM_TARGET_ADDRESS UINT64_C(0x0000123456789000)
#define LESSON_DEMAND_ADDRESS (LESSON_VMM_TARGET_ADDRESS + VMM_PAGE_SIZE)
#define LESSON_MAPPER_ADDRESS (LESSON_VMM_TARGET_ADDRESS + (UINT64_C(1) << 39))
#define LESSON_MAPPER_REUSE_ADDRESS (LESSON_MAPPER_ADDRESS + VMM_PAGE_SIZE)
#define LESSON_VMM_ALIAS_MARKER UINT64_C(0x30c0ffee30c0ffee)
#define LESSON_DEMAND_MARKER UINT64_C(0x31d00d0031d00d00)
#define LESSON_MAPPER_MARKER UINT64_C(0x33a44a0033a44a00)
#define LESSON_MAPPER_REUSE_MARKER UINT64_C(0x33b55b0033b55b00)
#define IDT_ENTRY_COUNT 256

struct idt_gate {
    uint16_t offset_low;
    uint16_t selector;
    uint8_t ist;
    uint8_t type_attributes;
    uint16_t offset_middle;
    uint32_t offset_high;
    uint32_t reserved;
} __attribute__((packed));

struct idtr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

static struct idt_gate kernel_idt[IDT_ENTRY_COUNT] __attribute__((aligned(16)));

struct demand_page_context {
    bool armed;
    uint64_t virtual_page;
    uint64_t physical_address;
    uint64_t *pte;
};

/* The assembly exception entry can change this state outside normal C control flow. */
static volatile struct demand_page_context demand_page;

extern void faults_idt_load(const struct idtr *descriptor);
extern void page_fault_entry(void);

__attribute__((noreturn))
static void halt_forever(void);

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

static void idt_set_gate(uint8_t vector, void (*handler)(void)) {
    const uintptr_t address = (uintptr_t)handler;

    kernel_idt[vector] = (struct idt_gate){
        .offset_low = (uint16_t)address,
        .selector = 0x28,
        .ist = 0,
        .type_attributes = 0x8e,
        .offset_middle = (uint16_t)(address >> 16),
        .offset_high = (uint32_t)(address >> 32),
        .reserved = 0,
    };
}

static void page_faults_install(void) {
    idt_set_gate(14, page_fault_entry);

    const struct idtr descriptor = {
        .limit = sizeof(kernel_idt) - 1,
        .base = (uintptr_t)kernel_idt,
    };
    faults_idt_load(&descriptor);
}

static uint64_t read_cr2(void) {
    uint64_t value;
    __asm__ volatile("mov %%cr2, %0" : "=r"(value));
    return value;
}

static uint64_t read_cr3(void) {
    uint64_t value;
    __asm__ volatile("mov %%cr3, %0" : "=r"(value));
    return value;
}

static void write_cr3(uint64_t value) {
    /* Architecture bridge: MOV to CR3 selects a new translation root and flushes non-global TLB entries. */
    __asm__ volatile("mov %0, %%cr3" : : "r"(value) : "memory");
}

static void invalidate_page(uint64_t virtual_address) {
    /* Architecture bridge: discard any cached translation for this one VA. */
    __asm__ volatile("invlpg (%0)" : : "r"((uintptr_t)virtual_address) : "memory");
}

static uint64_t read_rsp(void) {
    uint64_t value;
    __asm__ volatile("mov %%rsp, %0" : "=r"(value));
    return value;
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

void page_fault_handler(uint64_t error_code, const struct interrupt_frame *frame) {
    const uint64_t address = read_cr2();
    struct page_fault_report report;

    if (frame == NULL || !page_fault_decode(address, error_code, frame->rip, &report)) {
        debug_puts("PF:DECODE:FAIL\n");
        halt_forever();
    }

    if (demand_page.armed) {
        debug_puts("DEMAND:PF:CR2=");
        debug_hex64(report.address);
        debug_putc('\n');
        debug_puts("DEMAND:PF:ERROR=");
        debug_hex64(report.error_code);
        debug_putc('\n');
        debug_puts("DEMAND:PF:RIP=");
        debug_hex64(report.rip);
        debug_putc('\n');
        debug_puts("DEMAND:PTE-BEFORE=");
        debug_hex64(demand_page.pte == NULL ? UINT64_MAX : *demand_page.pte);
        debug_putc('\n');

        if (!vmm_resolve_demand_write(&report,
                                      demand_page.virtual_page,
                                      demand_page.physical_address,
                                      demand_page.pte)) {
            debug_puts("DEMAND:MAP:FAIL\n");
            halt_forever();
        }

        demand_page.armed = false;
        invalidate_page(demand_page.virtual_page);
        debug_puts("DEMAND:PTE-AFTER=");
        debug_hex64(*demand_page.pte);
        debug_putc('\n');
        debug_puts("DEMAND:MAP:OK\n");
        return;
    }

    debug_puts("PF:CR2=");
    debug_hex64(report.address);
    debug_putc('\n');
    debug_puts("PF:ERROR=");
    debug_hex64(report.error_code);
    debug_putc('\n');
    debug_puts("PF:RIP=");
    debug_hex64(report.rip);
    debug_putc('\n');
    debug_puts("PF:PRESENT=");
    debug_hex64(report.present);
    debug_putc('\n');
    debug_puts("PF:WRITE=");
    debug_hex64(report.write);
    debug_putc('\n');
    debug_puts("PF:USER=");
    debug_hex64(report.user);
    debug_putc('\n');
    debug_puts("PF:RSVD=");
    debug_hex64(report.reserved_write);
    debug_putc('\n');
    debug_puts("PF:FETCH=");
    debug_hex64(report.instruction_fetch);
    debug_putc('\n');

    if (report.address == LESSON_PAGE_FAULT_ADDRESS && report.error_code == PAGE_FAULT_WRITE &&
        !report.present && report.write && !report.user && !report.reserved_write && !report.instruction_fetch) {
        debug_puts("PF:DIAG:OK\n");
    } else {
        debug_puts("PF:DIAG:FAIL\n");
    }

    halt_forever();
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
        halt_forever();
    }

    page_faults_install();
    debug_puts("PF:IDT:OK\n");

    struct vmm_page_table_path kernel_path = {
        .pml4_pa = second_page,
        .pdpt_pa = PMM_NO_PAGE,
        .pd_pa = PMM_NO_PAGE,
        .pt_pa = PMM_NO_PAGE,
        .pml4 = NULL,
        .pdpt = NULL,
        .pd = NULL,
        .pt = NULL,
    };
    uint64_t demand_physical_page = PMM_NO_PAGE;
    uint64_t *demand_hhdm_alias = NULL;

    if (!pmm_alloc_page(&allocator, &kernel_path.pdpt_pa) ||
        !pmm_alloc_page(&allocator, &kernel_path.pd_pa) ||
        !pmm_alloc_page(&allocator, &kernel_path.pt_pa) ||
        !pmm_alloc_page(&allocator, &demand_physical_page) ||
        !hhdm_prepare_page(hhdm_response->offset, kernel_path.pml4_pa, &kernel_path.pml4) ||
        !hhdm_prepare_page(hhdm_response->offset, kernel_path.pdpt_pa, &kernel_path.pdpt) ||
        !hhdm_prepare_page(hhdm_response->offset, kernel_path.pd_pa, &kernel_path.pd) ||
        !hhdm_prepare_page(hhdm_response->offset, kernel_path.pt_pa, &kernel_path.pt) ||
        !hhdm_prepare_page(hhdm_response->offset, demand_physical_page, &demand_hhdm_alias)) {
        debug_puts("VMM:FRAMES:FAIL\n");
        halt_forever();
    }

    debug_puts("VMM:FRAMES:OK\n");
    debug_puts("VMM:ROOT-PA=");
    debug_hex64(kernel_path.pml4_pa);
    debug_putc('\n');
    debug_puts("VMM:PDPT-PA=");
    debug_hex64(kernel_path.pdpt_pa);
    debug_putc('\n');
    debug_puts("VMM:PD-PA=");
    debug_hex64(kernel_path.pd_pa);
    debug_putc('\n');
    debug_puts("VMM:PT-PA=");
    debug_hex64(kernel_path.pt_pa);
    debug_putc('\n');
    debug_puts("VMM:TARGET-VA=");
    debug_hex64(LESSON_VMM_TARGET_ADDRESS);
    debug_putc('\n');
    debug_puts("VMM:TARGET-PA=");
    debug_hex64(first_page);
    debug_putc('\n');

    if (!vmm_map_single_4k(&kernel_path, LESSON_VMM_TARGET_ADDRESS, first_page)) {
        debug_puts("VMM:LINK:FAIL\n");
    } else {
        const uint64_t pml4_index = VMM_PML4_INDEX(LESSON_VMM_TARGET_ADDRESS);
        const uint64_t pdpt_index = VMM_PDPT_INDEX(LESSON_VMM_TARGET_ADDRESS);
        const uint64_t pd_index = VMM_PD_INDEX(LESSON_VMM_TARGET_ADDRESS);
        const uint64_t pt_index = VMM_PT_INDEX(LESSON_VMM_TARGET_ADDRESS);
        const uint64_t active_cr3 = read_cr3();

        debug_puts("VMM:PML4-INDEX=");
        debug_hex64(pml4_index);
        debug_putc('\n');
        debug_puts("VMM:PDPT-INDEX=");
        debug_hex64(pdpt_index);
        debug_putc('\n');
        debug_puts("VMM:PD-INDEX=");
        debug_hex64(pd_index);
        debug_putc('\n');
        debug_puts("VMM:PT-INDEX=");
        debug_hex64(pt_index);
        debug_putc('\n');
        debug_puts("VMM:PML4E=");
        debug_hex64(kernel_path.pml4[pml4_index]);
        debug_putc('\n');
        debug_puts("VMM:PDPTE=");
        debug_hex64(kernel_path.pdpt[pdpt_index]);
        debug_putc('\n');
        debug_puts("VMM:PDE=");
        debug_hex64(kernel_path.pd[pd_index]);
        debug_putc('\n');
        debug_puts("VMM:PTE=");
        debug_hex64(kernel_path.pt[pt_index]);
        debug_putc('\n');
        debug_puts("VMM:ACTIVE-CR3=");
        debug_hex64(active_cr3);
        debug_putc('\n');

        const uint64_t table_flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
        const bool table_path_valid = kernel_path.pml4[pml4_index] == (kernel_path.pdpt_pa | table_flags) &&
                                      kernel_path.pdpt[pdpt_index] == (kernel_path.pd_pa | table_flags) &&
                                      kernel_path.pd[pd_index] == (kernel_path.pt_pa | table_flags) &&
                                      kernel_path.pt[pt_index] == (first_page | table_flags) &&
                                      (active_cr3 & VMM_PAGE_ADDRESS_MASK) != kernel_path.pml4_pa;

        if (table_path_valid) {
            debug_puts("VMM:ROOT:INACTIVE\n");
            debug_puts("VMM:BUILD:OK\n");

            const uint64_t old_cr3 = active_cr3;
            const uint64_t old_root_pa = old_cr3 & VMM_PAGE_ADDRESS_MASK;
            const uint64_t stack_address = read_rsp();
            const uint64_t preserved_index = VMM_PML4_INDEX(LESSON_VMM_TARGET_ADDRESS);
            const uint64_t kernel_index = VMM_PML4_INDEX((uint64_t)(uintptr_t)limine_kernel_main);
            const uint64_t hhdm_index = VMM_PML4_INDEX(hhdm_response->offset);
            const uint64_t stack_index = VMM_PML4_INDEX(stack_address);
            const uint64_t *old_root = NULL;

            if (old_root_pa <= UINT64_MAX - hhdm_response->offset) {
                old_root = (const uint64_t *)(uintptr_t)(hhdm_response->offset + old_root_pa);
            }

            if (!vmm_clone_root_preserving_entry(kernel_path.pml4, old_root, preserved_index)) {
                debug_puts("VMM:CLONE:FAIL\n");
            } else {
                const uint64_t old_kernel_entry = old_root[kernel_index];
                const uint64_t copied_kernel_entry = kernel_path.pml4[kernel_index];
                const uint64_t old_hhdm_entry = old_root[hhdm_index];
                const uint64_t copied_hhdm_entry = kernel_path.pml4[hhdm_index];
                const uint64_t old_stack_entry = old_root[stack_index];
                const uint64_t copied_stack_entry = kernel_path.pml4[stack_index];

                debug_puts("VMM:CLONE:OK\n");
                debug_puts("VMM:OLD-CR3=");
                debug_hex64(old_cr3);
                debug_putc('\n');
                debug_puts("VMM:PRESERVED-INDEX=");
                debug_hex64(preserved_index);
                debug_putc('\n');
                debug_puts("VMM:KERNEL-PML4-INDEX=");
                debug_hex64(kernel_index);
                debug_putc('\n');
                debug_puts("VMM:HHDM-PML4-INDEX=");
                debug_hex64(hhdm_index);
                debug_putc('\n');
                debug_puts("VMM:STACK-VA=");
                debug_hex64(stack_address);
                debug_putc('\n');
                debug_puts("VMM:STACK-PML4-INDEX=");
                debug_hex64(stack_index);
                debug_putc('\n');
                debug_puts("VMM:KERNEL-OLD-PML4E=");
                debug_hex64(old_kernel_entry);
                debug_putc('\n');
                debug_puts("VMM:KERNEL-COPIED-PML4E=");
                debug_hex64(copied_kernel_entry);
                debug_putc('\n');
                debug_puts("VMM:HHDM-OLD-PML4E=");
                debug_hex64(old_hhdm_entry);
                debug_putc('\n');
                debug_puts("VMM:HHDM-COPIED-PML4E=");
                debug_hex64(copied_hhdm_entry);
                debug_putc('\n');
                debug_puts("VMM:STACK-OLD-PML4E=");
                debug_hex64(old_stack_entry);
                debug_putc('\n');
                debug_puts("VMM:STACK-COPIED-PML4E=");
                debug_hex64(copied_stack_entry);
                debug_putc('\n');

                volatile uint64_t *target_alias = (volatile uint64_t *)(uintptr_t)LESSON_VMM_TARGET_ADDRESS;
                volatile uint64_t *hhdm_alias = (volatile uint64_t *)(uintptr_t)(hhdm_response->offset + first_page);
                const uint64_t target_before = *hhdm_alias;

                write_cr3(kernel_path.pml4_pa);

                const uint64_t new_cr3 = read_cr3();
                *target_alias = LESSON_VMM_ALIAS_MARKER;
                const uint64_t target_after = *target_alias;
                const uint64_t hhdm_after = *hhdm_alias;

                debug_puts("VMM:NEW-CR3=");
                debug_hex64(new_cr3);
                debug_putc('\n');
                debug_puts("VMM:TARGET-BEFORE=");
                debug_hex64(target_before);
                debug_putc('\n');
                debug_puts("VMM:TARGET-AFTER=");
                debug_hex64(target_after);
                debug_putc('\n');
                debug_puts("VMM:HHDM-AFTER=");
                debug_hex64(hhdm_after);
                debug_putc('\n');

                const bool activation_valid =
                    (new_cr3 & VMM_PAGE_ADDRESS_MASK) == kernel_path.pml4_pa &&
                    target_before == 0 && target_after == LESSON_VMM_ALIAS_MARKER &&
                    hhdm_after == LESSON_VMM_ALIAS_MARKER;

                if (activation_valid) {
                    debug_puts("VMM:ALIAS:OK\n");
                    debug_puts("VMM:ACTIVATE:OK\n");

                    uint64_t policy_probe_pte = 0;
                    const struct page_fault_report policy_probe = {
                        .address = LESSON_DEMAND_ADDRESS,
                        .error_code = PAGE_FAULT_WRITE,
                        .rip = 0,
                        .present = false,
                        .write = true,
                        .user = false,
                        .reserved_write = false,
                        .instruction_fetch = false,
                    };
                    const uint64_t demand_pte_index = VMM_PT_INDEX(LESSON_DEMAND_ADDRESS);
                    const uint64_t expected_demand_pte = demand_physical_page | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
                    uint64_t *walked_target_pte = NULL;
                    uint64_t *walked_demand_pte = NULL;
                    const uint64_t active_root_pa = read_cr3() & VMM_PAGE_ADDRESS_MASK;
                    const bool walk_valid =
                        vmm_walk_to_pte(active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_VMM_TARGET_ADDRESS,
                                        &walked_target_pte) &&
                        vmm_walk_to_pte(active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_DEMAND_ADDRESS,
                                        &walked_demand_pte) &&
                        walked_target_pte == &kernel_path.pt[pt_index] &&
                        walked_demand_pte == &kernel_path.pt[demand_pte_index] &&
                        (*walked_target_pte &
                         (VMM_PAGE_ADDRESS_MASK | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE)) ==
                            (first_page | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE) &&
                        *walked_demand_pte == 0;

                    debug_puts("VMM:WALK:ROOT-PA=");
                    debug_hex64(active_root_pa);
                    debug_putc('\n');
                    debug_puts("VMM:WALK:MAPPED-VA=");
                    debug_hex64(LESSON_VMM_TARGET_ADDRESS);
                    debug_putc('\n');
                    debug_puts("VMM:WALK:MAPPED-PTE=");
                    debug_hex64(walked_target_pte == NULL ? UINT64_MAX : *walked_target_pte);
                    debug_putc('\n');
                    debug_puts("VMM:WALK:EMPTY-VA=");
                    debug_hex64(LESSON_DEMAND_ADDRESS);
                    debug_putc('\n');
                    debug_puts("VMM:WALK:EMPTY-PTE=");
                    debug_hex64(walked_demand_pte == NULL ? UINT64_MAX : *walked_demand_pte);
                    debug_putc('\n');
                    debug_puts(walk_valid ? "VMM:WALK:OK\n" : "VMM:WALK:RED\n");

                    uint64_t mapper_physical_page = PMM_NO_PAGE;
                    uint64_t reuse_physical_page = PMM_NO_PAGE;
                    uint64_t *mapper_hhdm_alias = NULL;
                    uint64_t *reuse_hhdm_alias = NULL;
                    struct vmm_map_result mapper_result = {
                        .pte = NULL,
                        .allocated_table_count = UINT64_MAX,
                    };
                    struct vmm_map_result reuse_result = {
                        .pte = NULL,
                        .allocated_table_count = UINT64_MAX,
                    };
                    struct vmm_unmap_result unmap_result = {
                        .physical_address = UINT64_MAX,
                        .old_pte = UINT64_MAX,
                    };
                    const uint64_t mapper_pml4_index = VMM_PML4_INDEX(LESSON_MAPPER_ADDRESS);
                    const uint64_t mapper_parent_before = kernel_path.pml4[mapper_pml4_index];

                    if (!pmm_alloc_page(&allocator, &mapper_physical_page) ||
                        !hhdm_prepare_page(hhdm_response->offset, mapper_physical_page, &mapper_hhdm_alias) ||
                        !pmm_alloc_page(&allocator, &reuse_physical_page) ||
                        !hhdm_prepare_page(hhdm_response->offset, reuse_physical_page, &reuse_hhdm_alias)) {
                        debug_puts("VMM:MAP4K:INFRA:FAIL\n");
                        halt_forever();
                    }

                    const uint64_t mapper_free_before = allocator.free_pages;
                    const bool mapper_called =
                        walk_valid &&
                        vmm_map_page_4k(&allocator,
                                        active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_MAPPER_ADDRESS,
                                        mapper_physical_page,
                                        &mapper_result);
                    const uint64_t mapper_free_after = allocator.free_pages;
                    uint64_t *mapper_walked_pte = NULL;
                    const bool mapper_structure_valid =
                        mapper_called && mapper_parent_before == 0 && mapper_result.allocated_table_count == 3 &&
                        mapper_free_after == mapper_free_before - 3 && mapper_result.pte != NULL &&
                        *mapper_result.pte ==
                            (mapper_physical_page | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE) &&
                        vmm_walk_to_pte(active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_MAPPER_ADDRESS,
                                        &mapper_walked_pte) &&
                        mapper_walked_pte == mapper_result.pte;

                    uint64_t mapper_virtual_value = 0;
                    uint64_t mapper_hhdm_value = 0;
                    if (mapper_structure_valid) {
                        invalidate_page(LESSON_MAPPER_ADDRESS);
                        *(volatile uint64_t *)(uintptr_t)LESSON_MAPPER_ADDRESS = LESSON_MAPPER_MARKER;
                        mapper_virtual_value = *(volatile uint64_t *)(uintptr_t)LESSON_MAPPER_ADDRESS;
                        mapper_hhdm_value = *mapper_hhdm_alias;
                    }

                    const bool mapper_valid = mapper_structure_valid &&
                                              mapper_virtual_value == LESSON_MAPPER_MARKER &&
                                              mapper_hhdm_value == LESSON_MAPPER_MARKER;
                    const uint64_t reuse_free_before = allocator.free_pages;
                    const bool reuse_called =
                        mapper_valid &&
                        vmm_map_page_4k(&allocator,
                                        active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_MAPPER_REUSE_ADDRESS,
                                        reuse_physical_page,
                                        &reuse_result);
                    const uint64_t reuse_free_after = allocator.free_pages;
                    uint64_t *reuse_walked_pte = NULL;
                    const bool reuse_structure_valid =
                        reuse_called && reuse_result.allocated_table_count == 0 &&
                        reuse_free_after == reuse_free_before && reuse_result.pte != NULL &&
                        *reuse_result.pte ==
                            (reuse_physical_page | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE) &&
                        vmm_walk_to_pte(active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_MAPPER_REUSE_ADDRESS,
                                        &reuse_walked_pte) &&
                        reuse_walked_pte == reuse_result.pte;

                    uint64_t reuse_virtual_value = 0;
                    uint64_t reuse_hhdm_value = 0;
                    if (reuse_structure_valid) {
                        invalidate_page(LESSON_MAPPER_REUSE_ADDRESS);
                        *(volatile uint64_t *)(uintptr_t)LESSON_MAPPER_REUSE_ADDRESS = LESSON_MAPPER_REUSE_MARKER;
                        reuse_virtual_value = *(volatile uint64_t *)(uintptr_t)LESSON_MAPPER_REUSE_ADDRESS;
                        reuse_hhdm_value = *reuse_hhdm_alias;
                    }
                    const bool reuse_valid = reuse_structure_valid &&
                                             reuse_virtual_value == LESSON_MAPPER_REUSE_MARKER &&
                                             reuse_hhdm_value == LESSON_MAPPER_REUSE_MARKER;

                    const uint64_t reuse_pte_before_unmap =
                        reuse_result.pte == NULL ? UINT64_MAX : *reuse_result.pte;
                    const uint64_t unmap_free_before = allocator.free_pages;
                    const bool unmap_called =
                        reuse_valid &&
                        vmm_unmap_page_4k(active_root_pa,
                                          hhdm_response->offset,
                                          LESSON_MAPPER_REUSE_ADDRESS,
                                          &unmap_result);
                    const uint64_t unmap_free_after = allocator.free_pages;
                    uint64_t *unmap_walked_pte = NULL;
                    const bool unmap_valid =
                        unmap_called && unmap_result.physical_address == reuse_physical_page &&
                        unmap_result.old_pte == reuse_pte_before_unmap &&
                        unmap_free_after == unmap_free_before &&
                        vmm_walk_to_pte(active_root_pa,
                                        hhdm_response->offset,
                                        LESSON_MAPPER_REUSE_ADDRESS,
                                        &unmap_walked_pte) &&
                        unmap_walked_pte == reuse_result.pte && *unmap_walked_pte == 0;
                    if (unmap_called) {
                        invalidate_page(LESSON_MAPPER_REUSE_ADDRESS);
                    }

                    debug_puts("VMM:MAP4K:VA=");
                    debug_hex64(LESSON_MAPPER_ADDRESS);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:PA=");
                    debug_hex64(mapper_physical_page);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:PML4-INDEX=");
                    debug_hex64(mapper_pml4_index);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:PARENT-BEFORE=");
                    debug_hex64(mapper_parent_before);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:FREE-BEFORE=");
                    debug_hex64(mapper_free_before);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:FREE-AFTER=");
                    debug_hex64(mapper_free_after);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:TABLES=");
                    debug_hex64(mapper_result.allocated_table_count);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:PTE=");
                    debug_hex64(mapper_result.pte == NULL ? UINT64_MAX : *mapper_result.pte);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:VALUE-VA=");
                    debug_hex64(mapper_virtual_value);
                    debug_putc('\n');
                    debug_puts("VMM:MAP4K:VALUE-HHDM=");
                    debug_hex64(mapper_hhdm_value);
                    debug_putc('\n');
                    debug_puts(mapper_valid ? "VMM:MAP4K:OK\n" : (mapper_called ? "VMM:MAP4K:FAIL\n" : "VMM:MAP4K:RED\n"));

                    debug_puts("VMM:REUSE:VA=");
                    debug_hex64(LESSON_MAPPER_REUSE_ADDRESS);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:PA=");
                    debug_hex64(reuse_physical_page);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:FREE-BEFORE=");
                    debug_hex64(reuse_free_before);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:FREE-AFTER=");
                    debug_hex64(reuse_free_after);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:TABLES=");
                    debug_hex64(reuse_result.allocated_table_count);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:VALUE-VA=");
                    debug_hex64(reuse_virtual_value);
                    debug_putc('\n');
                    debug_puts("VMM:REUSE:VALUE-HHDM=");
                    debug_hex64(reuse_hhdm_value);
                    debug_putc('\n');
                    debug_puts(reuse_valid ? "VMM:REUSE:OK\n" : (reuse_called ? "VMM:REUSE:FAIL\n" : "VMM:REUSE:RED\n"));

                    debug_puts("VMM:UNMAP:PA=");
                    debug_hex64(unmap_result.physical_address);
                    debug_putc('\n');
                    debug_puts("VMM:UNMAP:OLD-PTE=");
                    debug_hex64(unmap_result.old_pte);
                    debug_putc('\n');
                    debug_puts("VMM:UNMAP:PTE-AFTER=");
                    debug_hex64(unmap_walked_pte == NULL ? UINT64_MAX : *unmap_walked_pte);
                    debug_putc('\n');
                    debug_puts("VMM:UNMAP:FREE-BEFORE=");
                    debug_hex64(unmap_free_before);
                    debug_putc('\n');
                    debug_puts("VMM:UNMAP:FREE-AFTER=");
                    debug_hex64(unmap_free_after);
                    debug_putc('\n');
                    debug_puts(unmap_valid ? "VMM:UNMAP:OK\n" : (unmap_called ? "VMM:UNMAP:FAIL\n" : "VMM:UNMAP:RED\n"));

                    const bool demand_policy_valid =
                        vmm_resolve_demand_write(&policy_probe,
                                                 LESSON_DEMAND_ADDRESS,
                                                 demand_physical_page,
                                                 &policy_probe_pte) &&
                        policy_probe_pte == expected_demand_pte &&
                        kernel_path.pt[demand_pte_index] == 0;

                    if (!demand_policy_valid) {
                        debug_puts("DEMAND:POLICY:FAIL\n");
                    } else {
                        debug_puts("DEMAND:POLICY:OK\n");
                        debug_puts("DEMAND:VA=");
                        debug_hex64(LESSON_DEMAND_ADDRESS);
                        debug_putc('\n');
                        debug_puts("DEMAND:PA=");
                        debug_hex64(demand_physical_page);
                        debug_putc('\n');
                        debug_puts("DEMAND:PT-INDEX=");
                        debug_hex64(demand_pte_index);
                        debug_putc('\n');

                        demand_page = (struct demand_page_context){
                            .armed = true,
                            .virtual_page = LESSON_DEMAND_ADDRESS,
                            .physical_address = demand_physical_page,
                            .pte = &kernel_path.pt[demand_pte_index],
                        };

                        debug_puts("DEMAND:TRIGGER\n");
                        *(volatile uint64_t *)(uintptr_t)LESSON_DEMAND_ADDRESS = LESSON_DEMAND_MARKER;

                        const uint64_t demand_virtual_value =
                            *(volatile uint64_t *)(uintptr_t)LESSON_DEMAND_ADDRESS;
                        const uint64_t demand_hhdm_value = *demand_hhdm_alias;

                        debug_puts("DEMAND:VALUE-VA=");
                        debug_hex64(demand_virtual_value);
                        debug_putc('\n');
                        debug_puts("DEMAND:VALUE-HHDM=");
                        debug_hex64(demand_hhdm_value);
                        debug_putc('\n');

                        if (!demand_page.armed && demand_virtual_value == LESSON_DEMAND_MARKER &&
                            demand_hhdm_value == LESSON_DEMAND_MARKER) {
                            debug_puts("DEMAND:RESUME:OK\n");
                        } else {
                            debug_puts("DEMAND:RESUME:FAIL\n");
                            halt_forever();
                        }
                    }
                } else {
                    debug_puts("VMM:ACTIVATE:FAIL\n");
                    halt_forever();
                }
            }
        } else {
            debug_puts("VMM:BUILD:FAIL\n");
        }
    }

    debug_puts("PF:TRIGGER\n");
    *(volatile uint64_t *)(uintptr_t)LESSON_PAGE_FAULT_ADDRESS = UINT64_C(0x28);

    debug_puts("PF:UNEXPECTED-RETURN\n");
    halt_forever();
}
