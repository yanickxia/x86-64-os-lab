#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/demand-page-${$}.log"
unit_binary="build/demand-page-unit-${$}"
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
    [[ "$actual_output" == *"DEMAND:RESUME:OK"* && "$actual_output" == *"PF:DIAG:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"DEMAND:POLICY:FAIL"* ||
        "$actual_output" == *"DEMAND:MAP:FAIL"* || "$actual_output" == *"DEMAND:RESUME:FAIL"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"VMM:ACTIVATE:OK"* ]]; then
    print -u2 "demand-page check: lesson-30 active kernel page table is not ready"
    print -u2 "demand-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"DEMAND:POLICY:OK"* ]]; then
    print -u2 "demand-page check: demand-write policy rejected the eligible synthetic fault"
    print -u2 "demand-page check: complete vmm_resolve_demand_write() in kernel/vmm.c"
    print -u2 "demand-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"DEMAND:MAP:OK"* || "$actual_output" != *"DEMAND:RESUME:OK"* ]]; then
    print -u2 "demand-page check: #PF did not install the PTE and resume the faulting store"
    print -u2 "demand-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"PF:DIAG:OK"* ]]; then
    print -u2 "demand-page check: the original fatal #PF diagnostic no longer works after recovery"
    print -u2 "demand-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

demand_va="$(read_value 'DEMAND:VA')"
demand_pa="$(read_value 'DEMAND:PA')"
pt_index="$(read_value 'DEMAND:PT-INDEX')"
fault_address="$(read_value 'DEMAND:PF:CR2')"
error_code="$(read_value 'DEMAND:PF:ERROR')"
fault_rip="$(read_value 'DEMAND:PF:RIP')"
pte_before="$(read_value 'DEMAND:PTE-BEFORE')"
pte_after="$(read_value 'DEMAND:PTE-AFTER')"
value_va="$(read_value 'DEMAND:VALUE-VA')"
value_hhdm="$(read_value 'DEMAND:VALUE-HHDM')"

values=("$demand_va" "$demand_pa" "$pt_index" "$fault_address" "$error_code" "$fault_rip"
    "$pte_before" "$pte_after" "$value_va" "$value_hhdm")
for value in "${values[@]}"; do
    if [[ -z "$value" ]]; then
        print -u2 "demand-page check: mapping, fault, PTE, or alias evidence is incomplete"
        print -u2 "demand-page output: ${actual_output//$'\n'/ | }"
        exit 1
    fi
done

if ! python3 - "$actual_output" "$demand_va" "$demand_pa" "$pt_index" "$fault_address" "$error_code" \
    "$fault_rip" "$pte_before" "$pte_after" "$value_va" "$value_hhdm" <<'PY'
import sys

(
    output,
    demand_va,
    demand_pa,
    pt_index,
    fault_address,
    error_code,
    fault_rip,
    pte_before,
    pte_after,
    value_va,
    value_hhdm,
) = sys.argv[1:]

demand_va, demand_pa, pt_index, fault_address, error_code, fault_rip, pte_before, pte_after, value_va, value_hhdm = (
    int(value, 16)
    for value in (demand_va, demand_pa, pt_index, fault_address, error_code, fault_rip, pte_before, pte_after, value_va, value_hhdm)
)

marker = 0x31D0_0D00_31D0_0D00
expected_va = 0x0000_1234_5678_A000

if demand_va != expected_va or fault_address != demand_va:
    print("demand-page check: CR2 does not identify the armed virtual page", file=sys.stderr)
    raise SystemExit(1)
if demand_pa & 0xFFF or pte_before != 0 or pte_after != demand_pa | 0x3:
    print("demand-page check: empty PTE did not become PA | PRESENT | WRITABLE", file=sys.stderr)
    raise SystemExit(1)
if pt_index != (demand_va >> 12) & 0x1FF:
    print("demand-page check: reported PT index does not match the demand VA", file=sys.stderr)
    raise SystemExit(1)
if error_code != 0x2 or fault_rip >> 32 != 0xFFFF_FFFF:
    print("demand-page check: expected a higher-half supervisor write fault with error code 0x2", file=sys.stderr)
    raise SystemExit(1)
if value_va != marker or value_hhdm != marker:
    print("demand-page check: resumed VA store and HHDM alias do not observe the same marker", file=sys.stderr)
    raise SystemExit(1)

ordered = [
    "DEMAND:TRIGGER",
    "DEMAND:PF:CR2=",
    "DEMAND:PTE-BEFORE=",
    "DEMAND:PTE-AFTER=",
    "DEMAND:MAP:OK",
    "DEMAND:RESUME:OK",
    "PF:TRIGGER",
    "PF:DIAG:OK",
]
positions = [output.find(marker_text) for marker_text in ordered]
if -1 in positions or positions != sorted(positions):
    print("demand-page check: recovery evidence is not in trigger → map → resume order", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

if ! cc -std=c11 -Wall -Wextra -Werror -Ikernel scripts/check-demand-page-unit.c kernel/vmm.c -o "$unit_binary"; then
    print -u2 "demand-page check: could not build the pure-C policy checks"
    exit 1
fi

if ! "$unit_binary"; then
    print -u2 "demand-page check: runtime recovered, but the helper violates its rejection contract"
    exit 1
fi

cleanup
trap - EXIT INT TERM

print "demand-page check passed: #PF installed one PTE and IRETQ retried the store"
print "demand-page mapping: VA=${demand_va}, PA=${demand_pa}, PTE ${pte_before} → ${pte_after}"
print "demand-page alias: resumed VA and HHDM both observed ${value_va}"
