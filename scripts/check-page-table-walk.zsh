#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/page-table-walk-${$}.log"
unit_binary="build/page-table-walk-unit-${$}"
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

if [[ "$actual_output" != *"VMM:ACTIVATE:OK"* || "$actual_output" != *"DEMAND:RESUME:OK"* ||
    "$actual_output" != *"PF:DIAG:OK"* ]]; then
    print -u2 "page-table walk check: lessons 30-31 are not ready"
    print -u2 "page-table walk output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"VMM:WALK:OK"* ]]; then
    print -u2 "page-table walk check: reusable walker is incomplete"
    print -u2 "page-table walk check: complete vmm_walk_to_pte() in kernel/vmm.c"
    print -u2 "page-table walk output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

root_pa="$(read_value 'VMM:WALK:ROOT-PA')"
mapped_va="$(read_value 'VMM:WALK:MAPPED-VA')"
mapped_pte="$(read_value 'VMM:WALK:MAPPED-PTE')"
empty_va="$(read_value 'VMM:WALK:EMPTY-VA')"
empty_pte="$(read_value 'VMM:WALK:EMPTY-PTE')"

for value in "$root_pa" "$mapped_va" "$mapped_pte" "$empty_va" "$empty_pte"; do
    if [[ -z "$value" ]]; then
        print -u2 "page-table walk check: root or leaf evidence is incomplete"
        print -u2 "page-table walk output: ${actual_output//$'\n'/ | }"
        exit 1
    fi
done

if ! python3 - "$actual_output" "$root_pa" "$mapped_va" "$mapped_pte" "$empty_va" "$empty_pte" <<'PY'
import sys

output = sys.argv[1]
root_pa, mapped_va, mapped_pte, empty_va, empty_pte = (int(value, 16) for value in sys.argv[2:])
address_mask = 0x000F_FFFF_FFFF_F000

if root_pa == 0 or root_pa & 0xFFF:
    print("page-table walk check: active root PA is not a non-zero aligned frame", file=sys.stderr)
    raise SystemExit(1)
if mapped_va != 0x0000_1234_5678_9000 or empty_va != mapped_va + 0x1000:
    print("page-table walk check: runtime did not probe the two adjacent lesson pages", file=sys.stderr)
    raise SystemExit(1)
if mapped_pte & 1 == 0 or mapped_pte & address_mask != 0:
    print("page-table walk check: mapped leaf does not describe lesson-29 frame zero", file=sys.stderr)
    raise SystemExit(1)
if empty_pte != 0:
    print("page-table walk check: walker confused an empty leaf with a missing parent", file=sys.stderr)
    raise SystemExit(1)

ordered = [
    "VMM:WALK:ROOT-PA=",
    "VMM:WALK:MAPPED-PTE=",
    "VMM:WALK:EMPTY-PTE=",
    "VMM:WALK:OK",
    "DEMAND:TRIGGER",
    "DEMAND:RESUME:OK",
]
positions = [output.find(marker) for marker in ordered]
if -1 in positions or positions != sorted(positions):
    print("page-table walk check: evidence is not in walk → demand recovery order", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

if ! cc -std=c11 -Wall -Wextra -Werror -Ikernel scripts/check-page-table-walk-unit.c kernel/vmm.c -o "$unit_binary"; then
    print -u2 "page-table walk check: could not build the pure-C boundary checks"
    exit 1
fi

if ! "$unit_binary"; then
    print -u2 "page-table walk check: runtime worked, but the walker violates its failure contract"
    exit 1
fi

cleanup
trap - EXIT INT TERM

print "page-table walk check passed: active root reached both adjacent leaf slots"
print "page-table walk mapped leaf: VA=${mapped_va}, PTE=${mapped_pte}"
print "page-table walk empty leaf: VA=${empty_va}, PTE=${empty_pte}"
