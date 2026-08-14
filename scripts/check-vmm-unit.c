#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "vmm.h"

#define TARGET_VA UINT64_C(0x0000123456789000)

static uint64_t pml4[512];
static uint64_t pdpt[512];
static uint64_t pd[512];
static uint64_t pt[512];

static struct vmm_page_table_path valid_path(void) {
    return (struct vmm_page_table_path){
        .pml4_pa = UINT64_C(0x1000),
        .pdpt_pa = UINT64_C(0x2000),
        .pd_pa = UINT64_C(0x3000),
        .pt_pa = UINT64_C(0x4000),
        .pml4 = pml4,
        .pdpt = pdpt,
        .pd = pd,
        .pt = pt,
    };
}

static bool expect_rejected(const char *case_name, struct vmm_page_table_path *path,
                            uint64_t virtual_address, uint64_t physical_address) {
    if (vmm_map_single_4k(path, virtual_address, physical_address)) {
        fprintf(stderr, "vmm validation check: accepted %s\n", case_name);
        return false;
    }
    return true;
}

int main(void) {
    memset(pml4, 0, sizeof(pml4));
    memset(pdpt, 0, sizeof(pdpt));
    memset(pd, 0, sizeof(pd));
    memset(pt, 0, sizeof(pt));

    struct vmm_page_table_path path = valid_path();
    if (!vmm_map_single_4k(&path, TARGET_VA, 0)) {
        fputs("vmm validation check: rejected the valid mapping contract\n", stderr);
        return 1;
    }

    if (pml4[VMM_PML4_INDEX(TARGET_VA)] != UINT64_C(0x2003) ||
        pdpt[VMM_PDPT_INDEX(TARGET_VA)] != UINT64_C(0x3003) ||
        pd[VMM_PD_INDEX(TARGET_VA)] != UINT64_C(0x4003) ||
        pt[VMM_PT_INDEX(TARGET_VA)] != UINT64_C(0x0003)) {
        fputs("vmm validation check: valid input produced incorrect entries\n", stderr);
        return 1;
    }

    if (!expect_rejected("NULL path", NULL, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pml4 = NULL;
    if (!expect_rejected("NULL PML4 pointer", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pdpt = NULL;
    if (!expect_rejected("NULL PDPT pointer", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pd = NULL;
    if (!expect_rejected("NULL PD pointer", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pt = NULL;
    if (!expect_rejected("NULL PT pointer", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pml4_pa |= 1;
    if (!expect_rejected("unaligned PML4 PA", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pdpt_pa |= 1;
    if (!expect_rejected("unaligned PDPT PA", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pd_pa |= 1;
    if (!expect_rejected("unaligned PD PA", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    path.pt_pa |= 1;
    if (!expect_rejected("unaligned PT PA", &path, TARGET_VA, 0)) {
        return 1;
    }

    path = valid_path();
    if (!expect_rejected("unaligned target PA", &path, TARGET_VA, 1)) {
        return 1;
    }

    path = valid_path();
    if (!expect_rejected("unaligned target VA", &path, TARGET_VA + 1, 0)) {
        return 1;
    }

    return 0;
}
