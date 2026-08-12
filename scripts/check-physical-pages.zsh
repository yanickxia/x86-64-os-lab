#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/physical-pages-${$}.log"
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
    [[ "$actual_output" == *"PMM:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"PMM:INIT:FAIL"* || "$actual_output" == *"PMM:ALLOC:FAIL"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"LIMINE:MEMMAP:OK"* ]]; then
    print -u2 "physical-page check: Limine memory map was not accepted"
    print -u2 "physical-page output: ${actual_output:-<empty>}"
    exit 1
fi

if [[ "$actual_output" != *"PMM:OK"* ]]; then
    print -u2 "physical-page check: memory map was accepted, but no two pages changed ownership"
    print -u2 "physical-page check: complete pmm_init() and pmm_alloc_page() in kernel/pmm.c"
    print -u2 "physical-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

free_before="$(read_value 'PMM:FREE-BEFORE')"
first_page="$(read_value 'PMM:FIRST')"
second_page="$(read_value 'PMM:SECOND')"
free_after="$(read_value 'PMM:FREE-AFTER')"
allocated="$(read_value 'PMM:ALLOCATED')"

if [[ -z "$free_before" || -z "$first_page" || -z "$second_page" || -z "$free_after" || -z "$allocated" ]]; then
    print -u2 "physical-page check: PMM evidence lines are incomplete"
    print -u2 "physical-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

(( first_page % 4096 == 0 )) || {
    print -u2 "physical-page check: first page is not 4 KiB aligned: ${first_page}"
    exit 1
}
(( second_page % 4096 == 0 )) || {
    print -u2 "physical-page check: second page is not 4 KiB aligned: ${second_page}"
    exit 1
}
(( first_page != second_page )) || {
    print -u2 "physical-page check: allocator returned the same physical page twice: ${first_page}"
    exit 1
}
(( allocated == 2 )) || {
    print -u2 "physical-page check: expected allocated_pages=2, got ${allocated}"
    exit 1
}
(( free_before >= 2 && free_after == free_before - 2 )) || {
    print -u2 "physical-page check: expected free_pages to decrease by 2"
    print -u2 "physical-page state: before=${free_before}, after=${free_after}"
    exit 1
}

print "physical-page check passed: two distinct aligned pages moved from free to kernel-owned"
print "physical-page state: first=${first_page}, second=${second_page}, free=${free_before}->${free_after}, allocated=${allocated}"
