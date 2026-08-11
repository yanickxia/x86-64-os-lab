#!/bin/zsh

set -eu

disk_image="$1"
expected_output="${2:-HelloPTLKCUR}"
monitor_socket="build/e820-monitor-${$}.sock"
output_file="build/e820-debugcon-${$}.log"
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

: > "$output_file"

qemu-system-x86_64 \
    -machine pc \
    -accel tcg \
    -m 128M \
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
    print -u2 "E820 check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
monitor_output="$(printf '%s\n' \
    'xp /1gx 0x5000' \
    'xp /1gx 0x5008' \
    'xp /1gx 0x5010' \
    'xp /1gx 0x5028' \
    'xp /1gx 0x7010' \
    'quit' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

actual_header="missing"
actual_count_capacity="missing"
actual_entries_ptr="missing"
actual_first_length="missing"
actual_c_ack="missing"

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    case "$line" in
        00005000:*) actual_header="${line##* }" ;;
        00005008:*) actual_count_capacity="${line##* }" ;;
        00005010:*) actual_entries_ptr="${line##* }" ;;
        00005028:*) actual_first_length="${line##* }" ;;
        00007010:*) actual_c_ack="${line##* }" ;;
    esac
done

expected_header="0x00180001464e4942"
expected_entries_ptr="0x0000000000005020"
expected_c_ack="0x214b4f4330323845"

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "E820 check: expected historical output '${expected_output}', got '${actual_output}'"
    exit 1
fi

if [[ "$actual_header" != "$expected_header" || "$actual_entries_ptr" != "$expected_entries_ptr" ]]; then
    print -u2 "E820 check: boot_info header layout does not match the stage 2 / C contract"
    print -u2 "E820 check: expected header/entries ${expected_header}/${expected_entries_ptr}"
    print -u2 "E820 check: actual header/entries ${actual_header}/${actual_entries_ptr}"
    exit 1
fi

if [[ "$actual_first_length" == "missing" || "$actual_first_length" == "0x0000000000000000" ]]; then
    print -u2 "E820 check: BIOS did not write a non-empty first memory-map entry at 0x5020"
    print -u2 "E820 check: actual first length ${actual_first_length}"
    exit 1
fi

if [[ "$actual_count_capacity" == "missing" ]]; then
    print -u2 "E820 check: boot_info entry_count/capacity qword is missing"
    exit 1
fi

count_capacity_value=$(( actual_count_capacity ))
entry_count=$(( count_capacity_value & 0xffffffff ))
entry_capacity=$(( (count_capacity_value >> 32) & 0xffffffff ))

if (( entry_capacity != 32 )); then
    print -u2 "E820 check: expected entry_capacity=32, got ${entry_capacity}"
    exit 1
fi

if (( entry_count == 0 )); then
    print -u2 "E820 check: firmware entries exist at 0x5020, but stage 2 published entry_count=0"
    print -u2 "E820 check: publish the internal BP count at the lesson-22 TODO"
    print -u2 "E820 check: C acknowledgement remains ${actual_c_ack} at 0x7010"
    exit 1
fi

if (( entry_count > entry_capacity )); then
    print -u2 "E820 check: entry_count ${entry_count} exceeds capacity ${entry_capacity}"
    exit 1
fi

if [[ "$actual_c_ack" != "$expected_c_ack" ]]; then
    print -u2 "E820 check: stage 2 published ${entry_count} entries, but C did not acknowledge boot_info"
    print -u2 "E820 check: expected ${expected_c_ack} at 0x7010, got ${actual_c_ack}"
    exit 1
fi

print "E820 check passed: stage 2 published ${entry_count}/${entry_capacity} entries and C consumed boot_info"
print "E820 state: header=${actual_header}, entries=0x5020, first_length=${actual_first_length}, C_ack=${actual_c_ack}, output='${actual_output}'"
