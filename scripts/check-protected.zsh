#!/bin/zsh

set -eu

boot_bin="$1"
expected_output="${2:-HelloP}"
monitor_socket="build/protected-monitor-${$}.sock"
output_file="build/protected-debugcon-${$}.log"
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
    print -u2 "protected-mode check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "protected-mode check: expected synchronization output '${expected_output}', got '${actual_output}'"
    exit 1
fi

monitor_output="$(printf 'info registers\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

cr0_tail="${monitor_output#*CR0=}"
cs_tail="${monitor_output#*CS =}"
ds_tail="${monitor_output#*DS =}"
ss_tail="${monitor_output#*SS =}"
cr0_state="${cr0_tail%%$'\r'*}"
cs_state="${cs_tail%%$'\r'*}"
ds_state="${ds_tail%%$'\r'*}"
ss_state="${ss_tail%%$'\r'*}"

if [[ "$monitor_output" != *"CR0=00000011"* || \
      "$monitor_output" != *"CS =0008"* || \
      "$monitor_output" != *"DS =0010"* || \
      "$monitor_output" != *"SS =0010"* ]]; then
    print -u2 "protected-mode check: expected CR0.PE=1, CS=0x0008, DS=SS=0x0010"
    print -u2 "protected-mode check: CR0=$cr0_state"
    print -u2 "protected-mode check: CS =$cs_state"
    print -u2 "protected-mode check: DS =$ds_state"
    print -u2 "protected-mode check: SS =$ss_state"
    exit 1
fi

print "protected-mode check passed: CR0.PE=1, CS=0x0008, DS=SS=0x0010"
print "protected-mode state: CR0=$cr0_state"
print "protected-mode state: CS =$cs_state"
print "protected-mode state: DS =$ds_state"
print "protected-mode state: SS =$ss_state"
