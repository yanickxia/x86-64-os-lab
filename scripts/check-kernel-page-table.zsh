#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/kernel-page-table-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi
    [[ -f "$output_file" ]] && unlink "$output_file" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

: > "$output_file"

qemu-system-x86_64 \
    -machine q35 \
    -accel tcg \
    -m 256M \
    -display none \
    -serial none \
    -parallel none \
    -monitor none \
    -no-reboot \
    -no-shutdown \
    -drive "if=pflash,unit=0,format=raw,readonly=on,file=$ovmf_code" \
    -device qemu-xhci \
    -drive "if=none,id=bootdisk,format=raw,readonly=on,file=$disk_image" \
    -device usb-storage,drive=bootdisk,removable=true \
    -boot order=d \
    -chardev "file,id=debugcon,path=$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon \
    >/dev/null 2>&1 &
qemu_pid="$!"

for attempt in {1..100}; do
    actual_output="$(< "$output_file")"
    [[ "$actual_output" == *"VMM:BUILD:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"VMM:FRAMES:FAIL"* ||
        "$actual_output" == *"VMM:LINK:FAIL"* || "$actual_output" == *"VMM:BUILD:FAIL"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"HHDM:PAGE:OK"* || "$actual_output" != *"PF:IDT:OK"* ]]; then
    print -u2 "kernel-page-table check: prerequisite HHDM or #PF safety-net evidence is missing"
    print -u2 "kernel-page-table output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"VMM:FRAMES:OK"* ]]; then
    print -u2 "kernel-page-table check: four cleared table frames were not prepared"
    print -u2 "kernel-page-table output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"VMM:BUILD:OK"* ]]; then
    print -u2 "kernel-page-table check: table frames exist, but the four-level path is not linked"
    print -u2 "kernel-page-table check: complete vmm_map_single_4k() in kernel/vmm.c"
    print -u2 "kernel-page-table output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

root_pa="$(read_value 'VMM:ROOT-PA')"
pdpt_pa="$(read_value 'VMM:PDPT-PA')"
pd_pa="$(read_value 'VMM:PD-PA')"
pt_pa="$(read_value 'VMM:PT-PA')"
target_va="$(read_value 'VMM:TARGET-VA')"
target_pa="$(read_value 'VMM:TARGET-PA')"
pml4_index="$(read_value 'VMM:PML4-INDEX')"
pdpt_index="$(read_value 'VMM:PDPT-INDEX')"
pd_index="$(read_value 'VMM:PD-INDEX')"
pt_index="$(read_value 'VMM:PT-INDEX')"
pml4e="$(read_value 'VMM:PML4E')"
pdpte="$(read_value 'VMM:PDPTE')"
pde="$(read_value 'VMM:PDE')"
pte="$(read_value 'VMM:PTE')"
active_cr3="$(read_value 'VMM:ACTIVE-CR3')"

values=("$root_pa" "$pdpt_pa" "$pd_pa" "$pt_pa" "$target_va" "$target_pa" "$pml4_index" "$pdpt_index"
    "$pd_index" "$pt_index" "$pml4e" "$pdpte" "$pde" "$pte" "$active_cr3")
for value in "${values[@]}"; do
    if [[ -z "$value" ]]; then
        print -u2 "kernel-page-table check: address, index, entry, or CR3 evidence is incomplete"
        print -u2 "kernel-page-table output: ${actual_output//$'\n'/ | }"
        exit 1
    fi
done

if ! python3 - "$root_pa" "$pdpt_pa" "$pd_pa" "$pt_pa" "$target_va" "$target_pa" \
    "$pml4_index" "$pdpt_index" "$pd_index" "$pt_index" "$pml4e" "$pdpte" "$pde" "$pte" "$active_cr3" <<'PY'
import sys

(
    root_pa,
    pdpt_pa,
    pd_pa,
    pt_pa,
    target_va,
    target_pa,
    pml4_index,
    pdpt_index,
    pd_index,
    pt_index,
    pml4e,
    pdpte,
    pde,
    pte,
    active_cr3,
) = (int(value, 16) for value in sys.argv[1:])

page_size = 4096
address_mask = 0x000F_FFFF_FFFF_F000
flags = 0x3

table_pages = [root_pa, pdpt_pa, pd_pa, pt_pa]
if any(page % page_size != 0 for page in table_pages + [target_pa]):
    print("kernel-page-table check: every table and target PA must be 4 KiB aligned", file=sys.stderr)
    raise SystemExit(1)
if len(set(table_pages)) != 4 or target_pa in table_pages:
    print("kernel-page-table check: the four table frames and target frame must have distinct ownership", file=sys.stderr)
    raise SystemExit(1)
if target_va != 0x0000_1234_5678_9000:
    print(f"kernel-page-table check: unexpected target VA {target_va:#018x}", file=sys.stderr)
    raise SystemExit(1)

expected_indices = (
    (target_va >> 39) & 0x1FF,
    (target_va >> 30) & 0x1FF,
    (target_va >> 21) & 0x1FF,
    (target_va >> 12) & 0x1FF,
)
actual_indices = (pml4_index, pdpt_index, pd_index, pt_index)
if actual_indices != expected_indices:
    print(
        f"kernel-page-table check: expected indices {expected_indices}, got {actual_indices}",
        file=sys.stderr,
    )
    raise SystemExit(1)

expected_entries = (pdpt_pa | flags, pd_pa | flags, pt_pa | flags, target_pa | flags)
actual_entries = (pml4e, pdpte, pde, pte)
if actual_entries != expected_entries:
    print(
        "kernel-page-table check: expected parent entries to contain the next table PA and the leaf to contain the target PA",
        file=sys.stderr,
    )
    print(f"expected entries: {[hex(value) for value in expected_entries]}", file=sys.stderr)
    print(f"actual entries:   {[hex(value) for value in actual_entries]}", file=sys.stderr)
    raise SystemExit(1)

if active_cr3 & address_mask == root_pa:
    print("kernel-page-table check: lesson 29 must not activate the new root", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

if [[ "$actual_output" != *"VMM:ROOT:INACTIVE"* ]]; then
    print -u2 "kernel-page-table check: the new root was not proven distinct from active CR3"
    exit 1
fi

unit_binary="build/vmm-unit-${$}"
if ! cc -std=c11 -Wall -Wextra -Werror -Ikernel scripts/check-vmm-unit.c kernel/vmm.c -o "$unit_binary"; then
    [[ -f "$unit_binary" ]] && unlink "$unit_binary"
    print -u2 "kernel-page-table check: could not build the pure-C validation checks"
    exit 1
fi

if ! "$unit_binary"; then
    unlink "$unit_binary"
    print -u2 "kernel-page-table check: the real mapping works, but invalid inputs are not rejected"
    print -u2 "kernel-page-table check: validate all four table PAs and the target VA/PA before writing entries"
    exit 1
fi
unlink "$unit_binary"

print "kernel-page-table check passed: four kernel-owned frames form one inactive 4 KiB mapping"
print "kernel-page-table path: VA=${target_va} -> PA=${target_pa}, indices=${pml4_index}/${pdpt_index}/${pd_index}/${pt_index}"
print "kernel-page-table entries: ${pml4e} -> ${pdpte} -> ${pde} -> ${pte}; active CR3=${active_cr3}"
