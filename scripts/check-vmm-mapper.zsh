#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/vmm-mapper-${$}.log"
unit_binary="build/vmm-mapper-unit-${$}"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi
    [[ -f "$output_file" ]] && unlink "$output_file" 2>/dev/null || true
    [[ -f "$unit_binary" ]] && unlink "$unit_binary" 2>/dev/null || true
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
    [[ "$actual_output" == *"PF:DIAG:OK"* ]] && break
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"VMM:WALK:OK"* || "$actual_output" != *"DEMAND:RESUME:OK"* ||
    "$actual_output" != *"PF:DIAG:OK"* ]]; then
    print -u2 "4 KiB mapper check: lessons 31-32 are not ready"
    print -u2 "4 KiB mapper output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" == *"VMM:MAP4K:RED"* ]]; then
    print -u2 "4 KiB mapper check: reusable mapper is incomplete"
    print -u2 "4 KiB mapper check: complete vmm_map_page_4k() in kernel/vmm_mapper.c"
    exit 1
fi

if [[ "$actual_output" != *"VMM:MAP4K:OK"* ]]; then
    print -u2 "4 KiB mapper check: mapper returned, but ownership or alias evidence is invalid"
    print -u2 "4 KiB mapper output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

target_va="$(read_value 'VMM:MAP4K:VA')"
target_pa="$(read_value 'VMM:MAP4K:PA')"
pml4_index="$(read_value 'VMM:MAP4K:PML4-INDEX')"
parent_before="$(read_value 'VMM:MAP4K:PARENT-BEFORE')"
free_before="$(read_value 'VMM:MAP4K:FREE-BEFORE')"
free_after="$(read_value 'VMM:MAP4K:FREE-AFTER')"
table_count="$(read_value 'VMM:MAP4K:TABLES')"
pte="$(read_value 'VMM:MAP4K:PTE')"
value_va="$(read_value 'VMM:MAP4K:VALUE-VA')"
value_hhdm="$(read_value 'VMM:MAP4K:VALUE-HHDM')"

values=("$target_va" "$target_pa" "$pml4_index" "$parent_before" "$free_before" "$free_after"
    "$table_count" "$pte" "$value_va" "$value_hhdm")
for value in "${values[@]}"; do
    if [[ -z "$value" ]]; then
        print -u2 "4 KiB mapper check: mapping evidence is incomplete"
        print -u2 "4 KiB mapper output: ${actual_output//$'\n'/ | }"
        exit 1
    fi
done

if ! python3 - "$target_va" "$target_pa" "$pml4_index" "$parent_before" "$free_before" "$free_after" \
    "$table_count" "$pte" "$value_va" "$value_hhdm" <<'PY'
import sys

(
    target_va,
    target_pa,
    pml4_index,
    parent_before,
    free_before,
    free_after,
    table_count,
    pte,
    value_va,
    value_hhdm,
) = (int(value, 16) for value in sys.argv[1:])

address_mask = 0x000F_FFFF_FFFF_F000
flags = 0x3
marker = 0x33A4_4A00_33A4_4A00

if target_va != 0x0000_12B4_5678_9000 or pml4_index != 0x25:
    print("4 KiB mapper check: target must enter the deliberately empty PML4[0x25] slot", file=sys.stderr)
    raise SystemExit(1)
if parent_before != 0 or table_count != 3:
    print("4 KiB mapper check: an empty PML4 parent must require PDPT, PD, and PT frames", file=sys.stderr)
    raise SystemExit(1)
if free_before < 3 or free_after != free_before - 3:
    print("4 KiB mapper check: PMM ownership did not decrease by exactly three table pages", file=sys.stderr)
    raise SystemExit(1)
if target_pa & 0xFFF or pte & address_mask != target_pa or pte & flags != flags:
    print("4 KiB mapper check: leaf PTE does not encode the target frame with P|RW", file=sys.stderr)
    raise SystemExit(1)
if value_va != marker or value_hhdm != marker:
    print("4 KiB mapper check: target VA and HHDM alias did not reach the same frame", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

if ! cc -std=c11 -Wall -Wextra -Werror -Ikernel \
    scripts/check-vmm-mapper-unit.c kernel/vmm_mapper.c -o "$unit_binary"; then
    print -u2 "4 KiB mapper check: could not build the pure-C boundary checks"
    exit 1
fi

if ! "$unit_binary"; then
    print -u2 "4 KiB mapper check: runtime mapping worked, but reuse or failure boundaries are incorrect"
    exit 1
fi

cleanup
trap - EXIT INT TERM

print "4 KiB mapper check passed: an empty PML4 slot gained three table frames"
print "4 KiB mapper mapping: VA=${target_va}, PA=${target_pa}, PTE=${pte}"
print "4 KiB mapper ownership: table pages=${table_count}, free=${free_before}->${free_after}"
