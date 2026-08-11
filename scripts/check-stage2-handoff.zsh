#!/bin/zsh

set -eu

disk_image="$1"
stage2_bin="$2"
stage2_load_address=$(( $3 ))
handshake_address=$(( $4 ))
expected_output="${5:-HelloPTLKCUR}"
stage2_size="$(wc -c < "$stage2_bin" | tr -d ' ')"
stage2_tail_address=$((stage2_load_address + stage2_size - 8))
monitor_socket="build/stage2-monitor-${$}.sock"
output_file="build/stage2-debugcon-${$}.log"
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

if (( stage2_size != 1024 )); then
    print -u2 "stage2 check: expected a 1024-byte stage2.bin, got ${stage2_size} bytes"
    exit 1
fi

head_fields=(${(z)"$(xxd -e -g 8 -l 8 "$stage2_bin")"})
tail_fields=(${(z)"$(xxd -e -g 8 -s $((stage2_size - 8)) -l 8 "$stage2_bin")"})
expected_head="0x${head_fields[2]}"
expected_tail="0x${tail_fields[2]}"
expected_handshake="0x4b4f324547415453"

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
    print -u2 "stage2 check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
load_hex="$(printf '0x%x' "$stage2_load_address")"
tail_hex="$(printf '0x%x' "$stage2_tail_address")"
handshake_hex="$(printf '0x%x' "$handshake_address")"
monitor_output="$(printf 'xp /1gx %s\nxp /1gx %s\nxp /1gx %s\nquit\n' \
    "$load_hex" "$tail_hex" "$handshake_hex" | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

load_label="$(printf '%08x' "$stage2_load_address")"
tail_label="$(printf '%08x' "$stage2_tail_address")"
handshake_label="$(printf '%08x' "$handshake_address")"
actual_head="missing"
actual_tail="missing"
actual_handshake="missing"

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    if [[ "$line" == "${load_label}:"* ]]; then
        actual_head="${line##* }"
    elif [[ "$line" == "${tail_label}:"* ]]; then
        actual_tail="${line##* }"
    elif [[ "$line" == "${handshake_label}:"* ]]; then
        actual_handshake="${line##* }"
    fi
done

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "stage2 check: expected historical output '${expected_output}', got '${actual_output}'"
    exit 1
fi

if [[ "$actual_head" != "$expected_head" || "$actual_tail" != "$expected_tail" ]]; then
    print -u2 "stage2 check: stage2.bin was not completely loaded at ${load_hex}..$(printf '0x%x' $((stage2_load_address + stage2_size - 1)))"
    print -u2 "stage2 check: expected head/tail ${expected_head}/${expected_tail}"
    print -u2 "stage2 check: actual head/tail ${actual_head}/${actual_tail}"
    exit 1
fi

if [[ "$actual_handshake" != "$expected_handshake" ]]; then
    print -u2 "stage2 check: stage 2 bytes are loaded at ${load_hex}, but its entry never executed"
    print -u2 "stage2 check: expected execution handshake ${expected_handshake} at ${handshake_hex}"
    print -u2 "stage2 check: call STAGE2_LOAD_ADDR from the lesson-21 TODO in boot/boot.asm"
    print -u2 "stage2 check: actual handshake ${actual_handshake}"
    exit 1
fi

print "stage2 check passed: stage 1 loaded and called stage 2, which returned to the historical boot path"
print "stage2 state: image ${load_hex}..$(printf '0x%x' $((stage2_load_address + stage2_size - 1))), handshake ${expected_handshake} at ${handshake_hex}, output='${actual_output}'"
