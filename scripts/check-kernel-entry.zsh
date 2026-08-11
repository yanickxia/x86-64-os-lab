#!/bin/zsh

set -eu

disk_image="$1"
expected_output_prefix="${2:-HelloPTLK}"
monitor_socket="build/kernel-entry-monitor-${$}.sock"
output_file="build/kernel-entry-debugcon-${$}.log"
qemu_pid=""

# Lesson 13 only needs to prove that execution entered the independently loaded
# 512-byte payload. Later lessons may intentionally park at another address in
# that sector, so do not couple this historical check to kernel_hang forever.
expected_rip_min="0000000000010000"
expected_rip_max="00000000000101ff"

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
actual_rip="missing"

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    if [[ "$line" == RIP=* ]]; then
        fields=(${(z)line})
        actual_rip="${fields[1]#RIP=}"
        break
    fi
done

if [[ "$actual_output" != "${expected_output_prefix}"* ]]; then
    print -u2 "kernel-entry check: the payload never wrote its own character to port 0xe9"
    print -u2 "kernel-entry check: expected debug output prefix '${expected_output_prefix}', got '${actual_output}'"
    failed=1
fi

if [[ "$actual_rip" == "missing" || "$actual_rip" < "$expected_rip_min" || "$actual_rip" > "$expected_rip_max" ]]; then
    print -u2 "kernel-entry check: RIP is outside the independently loaded payload"
    print -u2 "kernel-entry check: expected RIP in [0x10000, 0x10200), got 0x${actual_rip}"
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

print "kernel-entry check passed: payload output begins '${expected_output_prefix}', RIP=0x${actual_rip} is inside the payload, and CS=0x18 (CS64)"
print -- "$monitor_output"
