#!/bin/zsh

set -eu

boot_bin="$1"
gdb_socket="build/segments-gdb-${$}.sock"
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
    -drive if=floppy,format=raw,readonly=on,file="$boot_bin" &
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
    -x gdb/segments.gdb
