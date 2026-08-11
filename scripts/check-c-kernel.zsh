#!/bin/zsh

set -eu

disk_image="$1"
kernel_elf="$2"
expected_output="${3:-HelloPTLKC}"
output_file="build/c-kernel-debugcon-${$}.log"
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

symbols="$(x86_64-elf-nm -n "$kernel_elf")"
disassembly="$(x86_64-elf-objdump -d "$kernel_elf")"

if [[ "$symbols" != *" T kernel_main"* || "$symbols" != *" T debug_putc"* ]]; then
    print -u2 "C-kernel check: expected linked kernel_main and debug_putc symbols"
    exit 1
fi

if [[ "$disassembly" != *"call"*"<kernel_main>"* ]]; then
    print -u2 "C-kernel check: assembly entry does not call kernel_main"
    exit 1
fi

qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -display none \
    -serial none \
    -parallel none \
    -monitor none \
    -no-reboot \
    -boot order=a \
    -drive if=floppy,format=raw,readonly=on,file="$disk_image" \
    -chardev "file,id=debugcon,path=$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon &
qemu_pid="$!"

for attempt in {1..50}; do
    if [[ -f "$output_file" && "$(< "$output_file")" == "$expected_output" ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "C-kernel check: kernel_main did not produce the expected observable behavior"
    print -u2 "C-kernel check: expected '${expected_output}', got '${actual_output}'"
    print -u2 "C-kernel check: implement the single TODO in kernel/main.c"
    exit 1
fi

print "C-kernel check passed: assembly called kernel_main and received '${expected_output}'"
