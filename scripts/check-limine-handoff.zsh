#!/bin/zsh

set -eu

disk_image="$1"
kernel_elf="$2"
ovmf_code="$3"
output_file="build/limine-debugcon-${$}.log"
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

entry_point="$(x86_64-elf-readelf -h "$kernel_elf" | awk '/Entry point address:/ {print $4}')"
request_section="$(x86_64-elf-readelf -SW "$kernel_elf" | awk '$3 == ".limine_requests" {print $3}')"

if [[ "$entry_point" != 0xffffffff8* ]]; then
    print -u2 "Limine handoff check: expected a higher-half ELF entry, got ${entry_point}"
    exit 1
fi

if [[ "$request_section" != ".limine_requests" ]]; then
    print -u2 "Limine handoff check: .limine_requests was not retained in the ELF"
    exit 1
fi

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
    [[ "$actual_output" == *"LIMINE:MEMMAP:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"LIMINE:ENTRY"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"LIMINE:ENTRY"* ]]; then
    print -u2 "Limine handoff check: UEFI/Limine did not reach limine_kernel_main"
    print -u2 "Limine handoff output: ${actual_output:-<empty>}"
    exit 1
fi

if [[ "$actual_output" != *"LIMINE:MEMMAP:OK"* ]]; then
    print -u2 "Limine handoff check: the higher-half kernel entry ran, but the memory-map response was not accepted"
    print -u2 "Limine handoff check: complete accept_limine_handoff() in kernel/limine_main.c"
    print -u2 "Limine handoff output: ${actual_output}"
    exit 1
fi

print "Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response"
print "Limine handoff state: entry=${entry_point}, output='${actual_output//$'\n'/ | }'"
