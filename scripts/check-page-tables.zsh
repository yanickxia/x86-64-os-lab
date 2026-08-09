#!/bin/zsh

set -eu

boot_bin="$1"
expected_output="${2:-HelloPT}"
monitor_socket="build/page-tables-monitor-${$}.sock"
output_file="build/page-tables-debugcon-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi

    if [[ -S "$monitor_socket" ]]; then
        unlink "$monitor_socket" 2>/dev/null || true
    fi
    if [[ -f "$output_file" ]]; then
        unlink "$output_file" 2>/dev/null || true
    fi
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
    print -u2 "page-table check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "page-table check: expected synchronization output '${expected_output}', got '${actual_output}'"
    exit 1
fi
print "page-table synchronization output: received '${actual_output}' from I/O port 0xe9"

monitor_output="$(printf 'xp /1gx 0x1000\nxp /1gx 0x2000\nxp /1gx 0x3000\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

pml4_line="missing"
pdpt_line="missing"
pd_line="missing"
for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    case "$line" in
        00001000:*) pml4_line="$line" ;;
        00002000:*) pdpt_line="$line" ;;
        00003000:*) pd_line="$line" ;;
    esac
done

if [[ "$pml4_line" != *"0x0000000000002003"* || \
      "$pdpt_line" != *"0x0000000000003003"* || \
      "$pd_line" != *"0x0000000000000083"* ]]; then
    print -u2 "page-table check: expected PML4[0]=0x0000000000002003"
    print -u2 "page-table check: actual   PML4[0]=$pml4_line"
    print -u2 "page-table check: expected PDPT[0]=0x0000000000003003"
    print -u2 "page-table check: actual   PDPT[0]=$pdpt_line"
    print -u2 "page-table check: expected PD[0]  =0x0000000000000083"
    print -u2 "page-table check: actual   PD[0]  =$pd_line"
    exit 1
fi

print "page-table check passed: low 2 MiB identity map is present"
print "page-table state: PML4[0]=$pml4_line"
print "page-table state: PDPT[0]=$pdpt_line"
print "page-table state: PD[0]  =$pd_line"
