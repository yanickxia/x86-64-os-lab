#!/bin/zsh

set -eu

boot_bin="$1"
expected_output="${2:-X}"
output_file="build/debugcon.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi
}

trap cleanup EXIT INT TERM

: > "$output_file"

qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -display none \
    -serial none \
    -monitor none \
    -no-reboot \
    -boot order=a \
    -drive if=floppy,format=raw,readonly=on,file="$boot_bin" \
    -chardev file,id=debugcon,path="$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon &
qemu_pid="$!"

for attempt in {1..30}; do
    [[ -s "$output_file" ]] && break
    sleep 0.1
done

cleanup
trap - EXIT INT TERM

actual_output="$(< "$output_file")"

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "debug console: expected '${expected_output}', got '${actual_output}'"
    exit 1
fi

print "debug console check passed: received '${expected_output}' from I/O port 0xe9"
