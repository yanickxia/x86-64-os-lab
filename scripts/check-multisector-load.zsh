#!/bin/zsh

set -eu

disk_image="$1"
kernel_bin="$2"
expected_sectors="$3"
expected_output="${4:-HelloPTLKCUR}"
kernel_load_address=$((0x10000))
expected_bytes=$((expected_sectors * 512))
kernel_size="$(wc -c < "$kernel_bin" | tr -d ' ')"
tail_offset=$((expected_bytes - 8))
tail_address=$((kernel_load_address + tail_offset))
monitor_socket="build/multisector-monitor-${$}.sock"
output_file="build/multisector-debugcon-${$}.log"
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

if [[ "$kernel_size" != "$expected_bytes" ]]; then
    print -u2 "multi-sector check: expected ${expected_sectors} sectors (${expected_bytes} bytes), got ${kernel_size} bytes"
    exit 1
fi

expected_fields=(${(z)"$(xxd -e -g 8 -s "$tail_offset" -l 8 "$kernel_bin")"})
expected_tail="0x${expected_fields[2]}"

: > "$output_file"

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
    -device isa-debugcon,iobase=0xe9,chardev=debugcon \
    >/dev/null 2>&1 &
qemu_pid="$!"

for attempt in {1..50}; do
    if [[ -S "$monitor_socket" && "$(< "$output_file")" == "$expected_output" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$monitor_socket" ]]; then
    print -u2 "multi-sector check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
tail_address_hex="$(printf '0x%x' "$tail_address")"
monitor_output="$(printf 'xp /1gx %s\nquit\n' "$tail_address_hex" | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""
tail_address_label="$(printf '%08x' "$tail_address")"
actual_tail="missing"

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    if [[ "$line" == "${tail_address_label}:"* ]]; then
        actual_tail="${line##* }"
        break
    fi
done

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "multi-sector check: expected historical output '${expected_output}', got '${actual_output}'"
    exit 1
fi

if [[ "$monitor_output" != *"$expected_tail"* ]]; then
    print -u2 "multi-sector check: the kernel starts correctly, but its last sector was not loaded"
    print -u2 "multi-sector check: expected tail ${expected_tail} at physical ${tail_address_hex}"
    print -u2 "multi-sector check: load all KERNEL_SECTORS in boot/boot.asm"
    print -u2 "multi-sector check: actual tail ${actual_tail}"
    exit 1
fi

print "multi-sector check passed: ${expected_sectors} sectors loaded at physical 0x10000..$(printf '0x%x' $((kernel_load_address + expected_bytes - 1)))"
print "multi-sector state: tail ${expected_tail} is present at ${tail_address_hex}, output='${actual_output}'"
