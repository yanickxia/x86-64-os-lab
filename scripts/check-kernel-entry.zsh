#!/bin/zsh

set -eu

disk_image="$1"
expected_output_prefix="${2:-HelloPTLK}"
monitor_socket="build/kernel-entry-monitor-${$}.sock"
output_file="build/kernel-entry-debugcon-${$}.log"
qemu_pid=""

# kernel/payload.asm is assembled with `org 0x10000`:
#   0x10000  jmp short kernel_entry   (EB 08)
#   0x10002  db 'KERNEL64'            (8 bytes)
#   0x1000a  mov al, 'K'              (B0 4B)
#   0x1000c  out 0xe9, al             (E6 E9)
#   0x1000e  .hang: jmp .hang         (EB FE)
# So a payload that really took control parks its RIP at 0x1000e forever.
expected_rip="RIP=000000000001000e"

# A near jump does not reload CS. The payload must still run under the
# 64-bit code descriptor installed by lesson 11, selector 0x18.
expected_cs="CS =0018"
expected_cs_mode="CS64"

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
    if [[ -S "$monitor_socket" && -f "$output_file" && "$(< "$output_file")" == "${expected_output_prefix}"* ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$monitor_socket" ]]; then
    print -u2 "kernel-entry check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
monitor_output="$(printf 'info registers\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""
failed=0

if [[ "$actual_output" != "${expected_output_prefix}"* ]]; then
    print -u2 "kernel-entry check: the payload never wrote its own character to port 0xe9"
    print -u2 "kernel-entry check: expected debug output prefix '${expected_output_prefix}', got '${actual_output}'"
    failed=1
fi

if [[ "$monitor_output" != *"$expected_rip"* ]]; then
    print -u2 "kernel-entry check: RIP is not parked in the payload hang loop"
    print -u2 "kernel-entry check: expected ${expected_rip} (kernel/payload.asm .hang)"
    if [[ "$monitor_output" == *"RIP="* ]]; then
        rip_tail="${monitor_output#*RIP=}"
        print -u2 "kernel-entry check: actual RIP=${rip_tail%% *}"
    fi
    failed=1
fi

if [[ "$monitor_output" != *"$expected_cs"* || "$monitor_output" != *"$expected_cs_mode"* ]]; then
    print -u2 "kernel-entry check: the payload is not running under the 64-bit code descriptor"
    print -u2 "kernel-entry check: expected '${expected_cs}' and '${expected_cs_mode}'"
    failed=1
fi

if (( failed )); then
    print -u2 "kernel-entry check: actual monitor output:"
    print -u2 -- "$monitor_output"
    exit 1
fi

print "kernel-entry check passed: payload output begins '${expected_output_prefix}' and RIP=0x1000e under CS=0x18 (CS64)"
print -- "$monitor_output"
