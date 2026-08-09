#!/bin/zsh

set -eu

boot_bin="$1"
expected_output="${2:-Hello}"
monitor_socket="build/gdt-monitor-${$}.sock"
output_file="build/gdt-debugcon-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi

    [[ -S "$monitor_socket" ]] && unlink "$monitor_socket"
    [[ -f "$output_file" ]] && unlink "$output_file"
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
    -drive if=floppy,format=raw,readonly=on,file="$boot_bin" \
    -chardev "file,id=debugcon,path=$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon &
qemu_pid="$!"

for attempt in {1..50}; do
    if [[ -S "$monitor_socket" && -f "$output_file" && "$(< "$output_file")" == "$expected_output" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$monitor_socket" ]]; then
    print -u2 "GDT check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "GDT check: boot code did not reach its final loop; expected debug output '${expected_output}', got '${actual_output}'"
    exit 1
fi

monitor_output="$(printf 'info registers\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

expected_gdtr="GDT=     00007c50 00000017"
if [[ "$monitor_output" != *"$expected_gdtr"* ]]; then
    print -u2 "GDT check: expected GDTR base=0x00007c50 limit=0x0017 after boot code"
    if [[ "$monitor_output" == *"GDT="* ]]; then
        gdt_tail="${monitor_output#*GDT=}"
        gdt_state="${gdt_tail%%$'\r'*}"
        print -u2 "GDT check: QEMU reported GDT=${gdt_state}"
    fi
    exit 1
fi

print "GDT check passed: GDTR base=0x00007c50 limit=0x0017"
