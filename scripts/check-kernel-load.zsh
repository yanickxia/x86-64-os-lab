#!/bin/zsh

set -eu

disk_image="$1"
expected_output="${2:-HelloPTL}"
monitor_socket="build/kernel-load-monitor-${$}.sock"
output_file="build/kernel-load-debugcon-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi

    [[ -S "$monitor_socket" ]] && unlink "$monitor_socket" 2>/dev/null || true
    [[ -f "$output_file" ]] && unlink "$output_file" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -display none \
    -serial none \
    -parallel none \
    -monitor "unix:$monitor_socket,server=on,wait=off" \
    -no-reboot \
    -boot order=a \
    -drive if=floppy,format=raw,readonly=on,file="$disk_image" \
    -chardev "file,id=debugcon,path=$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon &
qemu_pid="$!"

for attempt in {1..50}; do
    if [[ -S "$monitor_socket" && -f "$output_file" && "$(< "$output_file")" == "$expected_output"* ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$monitor_socket" ]]; then
    print -u2 "kernel-load check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
if [[ "$actual_output" != "$expected_output"* ]]; then
    print -u2 "kernel-load check: expected synchronization prefix '${expected_output}', got '${actual_output}'"
    exit 1
fi

monitor_output="$(printf 'xp /2gx 0x10000\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

if [[ "$monitor_output" != *"0x4c454e52454b08eb"* || \
      "$monitor_output" != *"0xfeebe9e64bb03436"* ]]; then
    print -u2 "kernel-load check: expected sector-2 payload at physical 0x10000"
    print -u2 "kernel-load check: expected qwords 0x4c454e52454b08eb and 0xfeebe9e64bb03436"
    print -u2 "kernel-load check: actual monitor output:"
    print -u2 -- "$monitor_output"
    exit 1
fi

print "kernel-load check passed: sector 2 is present at physical 0x10000"
print -- "$monitor_output"
