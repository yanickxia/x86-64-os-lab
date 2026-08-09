#!/bin/zsh

set -eu

boot_bin="$1"
expected_output="${2:-HelloPTL}"
monitor_socket="build/long-mode-monitor-${$}.sock"
output_file="build/long-mode-debugcon-${$}.log"
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
    print -u2 "long-mode check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "long-mode check: expected synchronization output '${expected_output}', got '${actual_output}'"
    exit 1
fi

monitor_output="$(printf 'info registers\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

cr0_tail="${monitor_output#*CR0=}"
cs_tail="${monitor_output#*CS =}"
efer_tail="${monitor_output#*EFER=}"
cr0_state="${cr0_tail%%$'\r'*}"
cs_state="${cs_tail%%$'\r'*}"
efer_state="${efer_tail%%$'\r'*}"

if [[ "$monitor_output" != *"CR0=80000011"* || \
      "$monitor_output" != *"CR3=0000000000001000"* || \
      "$monitor_output" != *"CR4=00000020"* || \
      "$monitor_output" != *"EFER=0000000000000500"* || \
      "$monitor_output" != *"CS =0018"* || \
      "$monitor_output" != *"CS64"* ]]; then
    print -u2 "long-mode check: expected CR0.PG=1, CR3=0x1000, CR4.PAE=1, EFER.LME=LMA=1, CS=0x0018 CS64"
    print -u2 "long-mode check: CR0=$cr0_state"
    print -u2 "long-mode check: CS =$cs_state"
    print -u2 "long-mode check: EFER=$efer_state"
    exit 1
fi

print "long-mode check passed: CPU is executing 64-bit code"
print "long-mode state: CR0=$cr0_state"
print "long-mode state: CS =$cs_state"
print "long-mode state: EFER=$efer_state"
