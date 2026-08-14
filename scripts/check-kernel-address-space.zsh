#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/kernel-address-space-${$}.log"
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
    [[ "$actual_output" == *"VMM:ACTIVATE:OK"* && "$actual_output" == *"PF:DIAG:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"VMM:CLONE:FAIL"* ||
        "$actual_output" == *"VMM:ACTIVATE:FAIL"* || "$actual_output" == *"VMM:BUILD:FAIL"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"VMM:BUILD:OK"* ]]; then
    print -u2 "kernel-address-space check: lesson-29 mapping path is not ready"
    print -u2 "kernel-address-space output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"VMM:CLONE:OK"* ]]; then
    print -u2 "kernel-address-space check: the active root mappings were not copied into the new root"
    print -u2 "kernel-address-space check: complete vmm_clone_root_preserving_entry() in kernel/vmm.c"
    print -u2 "kernel-address-space output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"VMM:ACTIVATE:OK"* || "$actual_output" != *"VMM:ALIAS:OK"* ]]; then
    print -u2 "kernel-address-space check: CR3 changed, but the custom VA/HHDM alias proof did not survive"
    print -u2 "kernel-address-space output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"PF:DIAG:OK"* ]]; then
    print -u2 "kernel-address-space check: the post-switch #PF safety net did not survive"
    print -u2 "kernel-address-space output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

root_pa="$(read_value 'VMM:ROOT-PA')"
old_cr3="$(read_value 'VMM:OLD-CR3')"
new_cr3="$(read_value 'VMM:NEW-CR3')"
target_va="$(read_value 'VMM:TARGET-VA')"
preserved_index="$(read_value 'VMM:PRESERVED-INDEX')"
kernel_index="$(read_value 'VMM:KERNEL-PML4-INDEX')"
hhdm_index="$(read_value 'VMM:HHDM-PML4-INDEX')"
stack_va="$(read_value 'VMM:STACK-VA')"
stack_index="$(read_value 'VMM:STACK-PML4-INDEX')"
kernel_old="$(read_value 'VMM:KERNEL-OLD-PML4E')"
kernel_copied="$(read_value 'VMM:KERNEL-COPIED-PML4E')"
hhdm_old="$(read_value 'VMM:HHDM-OLD-PML4E')"
hhdm_copied="$(read_value 'VMM:HHDM-COPIED-PML4E')"
stack_old="$(read_value 'VMM:STACK-OLD-PML4E')"
stack_copied="$(read_value 'VMM:STACK-COPIED-PML4E')"
target_before="$(read_value 'VMM:TARGET-BEFORE')"
target_after="$(read_value 'VMM:TARGET-AFTER')"
hhdm_after="$(read_value 'VMM:HHDM-AFTER')"

values=("$root_pa" "$old_cr3" "$new_cr3" "$target_va" "$preserved_index" "$kernel_index" "$hhdm_index"
    "$stack_va" "$stack_index" "$kernel_old" "$kernel_copied" "$hhdm_old" "$hhdm_copied" "$stack_old"
    "$stack_copied" "$target_before" "$target_after" "$hhdm_after")
for value in "${values[@]}"; do
    if [[ -z "$value" ]]; then
        print -u2 "kernel-address-space check: CR3, root-entry, stack, or alias evidence is incomplete"
        print -u2 "kernel-address-space output: ${actual_output//$'\n'/ | }"
        exit 1
    fi
done

if ! python3 - "$root_pa" "$old_cr3" "$new_cr3" "$target_va" "$preserved_index" "$kernel_index" "$hhdm_index" \
    "$stack_va" "$stack_index" "$kernel_old" "$kernel_copied" "$hhdm_old" "$hhdm_copied" "$stack_old" \
    "$stack_copied" "$target_before" "$target_after" "$hhdm_after" <<'PY'
import sys

(
    root_pa,
    old_cr3,
    new_cr3,
    target_va,
    preserved_index,
    kernel_index,
    hhdm_index,
    stack_va,
    stack_index,
    kernel_old,
    kernel_copied,
    hhdm_old,
    hhdm_copied,
    stack_old,
    stack_copied,
    target_before,
    target_after,
    hhdm_after,
) = (int(value, 16) for value in sys.argv[1:])

address_mask = 0x000F_FFFF_FFFF_F000
marker = 0x30C0_FFEE_30C0_FFEE

if old_cr3 & address_mask == root_pa:
    print("kernel-address-space check: the pre-switch CR3 already used the new root", file=sys.stderr)
    raise SystemExit(1)
if new_cr3 & address_mask != root_pa:
    print("kernel-address-space check: CR3 does not select the kernel-owned root", file=sys.stderr)
    raise SystemExit(1)

expected_target_index = (target_va >> 39) & 0x1FF
if preserved_index != expected_target_index:
    print("kernel-address-space check: the custom target root slot was not preserved", file=sys.stderr)
    raise SystemExit(1)
if kernel_index != 0x1FF or hhdm_index != 0x100:
    print(
        f"kernel-address-space check: expected kernel/HHDM root indices 0x1ff/0x100, got {kernel_index:#x}/{hhdm_index:#x}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if stack_index != ((stack_va >> 39) & 0x1FF):
    print("kernel-address-space check: the reported stack root index does not match RSP", file=sys.stderr)
    raise SystemExit(1)

for role, old, copied in (
    ("kernel", kernel_old, kernel_copied),
    ("HHDM", hhdm_old, hhdm_copied),
    ("stack", stack_old, stack_copied),
):
    if old != copied or old & 1 == 0:
        print(f"kernel-address-space check: {role} root entry was not copied as a present mapping", file=sys.stderr)
        raise SystemExit(1)

if target_before != 0 or target_after != marker or hhdm_after != marker:
    print("kernel-address-space check: the custom VA and HHDM alias do not reach the same physical frame", file=sys.stderr)
    raise SystemExit(1)
PY
then
    exit 1
fi

unit_binary="build/vmm-clone-unit-${$}"
if ! cc -std=c11 -Wall -Wextra -Werror -Ikernel scripts/check-vmm-clone-unit.c kernel/vmm.c -o "$unit_binary"; then
    [[ -f "$unit_binary" ]] && unlink "$unit_binary"
    print -u2 "kernel-address-space check: could not build the pure-C root-clone checks"
    exit 1
fi

if ! "$unit_binary"; then
    unlink "$unit_binary"
    print -u2 "kernel-address-space check: the boot path worked, but the root-clone helper violates its API contract"
    exit 1
fi
unlink "$unit_binary"

print "kernel-address-space check passed: CR3 selects the kernel-owned root and live mappings survive"
print "kernel-address-space roots: old CR3=${old_cr3}, new CR3=${new_cr3}, root PA=${root_pa}"
print "kernel-address-space indices: custom=${preserved_index}, kernel=${kernel_index}, HHDM=${hhdm_index}, stack=${stack_index}"
print "kernel-address-space alias: ${target_va} and HHDM both observed ${target_after}"
