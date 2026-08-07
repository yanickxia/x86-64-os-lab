#!/bin/zsh

set -eu

boot_bin="$1"
gdb_socket="build/call-gdb-${$}.sock"
output_file="build/call-debugcon-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi

    if [[ -S "$gdb_socket" ]]; then
        unlink "$gdb_socket"
    fi
}

trap cleanup EXIT INT TERM

qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -S \
    -chardev socket,path="$gdb_socket",server=on,wait=off,id=gdb0 \
    -gdb chardev:gdb0 \
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
    [[ -S "$gdb_socket" ]] && break
    sleep 0.1
done

if [[ ! -S "$gdb_socket" ]]; then
    print -u2 "QEMU did not create the GDB socket"
    exit 1
fi

x86_64-elf-gdb \
    -q \
    -batch \
    -ex "target remote $gdb_socket" \
    -x gdb/call.gdb

actual_output="$(< "$output_file")"

if [[ "$actual_output" != "X" ]]; then
    print -u2 "putc output: expected 'X', got '${actual_output}'"
    exit 1
fi

print "putc output check passed: received 'X'"

