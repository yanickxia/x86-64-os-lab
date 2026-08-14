#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/page-fault-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi
    [[ -f "$output_file" ]] && unlink "$output_file" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

: > "$output_file"

qemu-system-x86_64 \
    -machine q35 \
    -accel tcg \
    -m 256M \
    -display none \
    -serial none \
    -parallel none \
    -monitor none \
    -no-reboot \
    -no-shutdown \
    -drive "if=pflash,unit=0,format=raw,readonly=on,file=$ovmf_code" \
    -device qemu-xhci \
    -drive "if=none,id=bootdisk,format=raw,readonly=on,file=$disk_image" \
    -device usb-storage,drive=bootdisk,removable=true \
    -boot order=d \
    -chardev "file,id=debugcon,path=$output_file" \
    -device isa-debugcon,iobase=0xe9,chardev=debugcon \
    >/dev/null 2>&1 &
qemu_pid="$!"

for attempt in {1..100}; do
    actual_output="$(< "$output_file")"
    [[ "$actual_output" == *"PF:DIAG:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"PF:DECODE:FAIL"* ||
        "$actual_output" == *"PF:DIAG:FAIL"* || "$actual_output" == *"PF:UNEXPECTED-RETURN"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"HHDM:PAGE:OK"* ]]; then
    print -u2 "page-fault check: prerequisite HHDM page evidence is missing"
    print -u2 "page-fault output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"PF:IDT:OK"* || "$actual_output" != *"PF:TRIGGER"* ]]; then
    print -u2 "page-fault check: the provided IDT/#PF trigger bridge was not reached"
    print -u2 "page-fault output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"PF:DIAG:OK"* ]]; then
    print -u2 "page-fault check: #PF reached C, but its CR2/error-code evidence was not decoded"
    print -u2 "page-fault check: complete page_fault_decode() in kernel/faults.c"
    print -u2 "page-fault output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

fault_address="$(read_value 'PF:CR2')"
error_code="$(read_value 'PF:ERROR')"
fault_rip="$(read_value 'PF:RIP')"
present="$(read_value 'PF:PRESENT')"
write="$(read_value 'PF:WRITE')"
user="$(read_value 'PF:USER')"
reserved_write="$(read_value 'PF:RSVD')"
instruction_fetch="$(read_value 'PF:FETCH')"

if [[ -z "$fault_address" || -z "$error_code" || -z "$fault_rip" || -z "$present" || -z "$write" ||
    -z "$user" || -z "$reserved_write" || -z "$instruction_fetch" ]]; then
    print -u2 "page-fault check: diagnostic evidence lines are incomplete"
    print -u2 "page-fault output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$fault_address" != "0x0000400000000000" ]]; then
    print -u2 "page-fault check: expected CR2=0x0000400000000000, got ${fault_address}"
    exit 1
fi

if [[ "$error_code" != "0x0000000000000002" ]]; then
    print -u2 "page-fault check: expected error code 0x2 for supervisor write to a non-present page, got ${error_code}"
    exit 1
fi

if [[ "$present" != "0x0000000000000000" || "$write" != "0x0000000000000001" ||
    "$user" != "0x0000000000000000" || "$reserved_write" != "0x0000000000000000" ||
    "$instruction_fetch" != "0x0000000000000000" ]]; then
    print -u2 "page-fault check: decoded error-code flags do not describe a supervisor data write to a non-present page"
    print -u2 "page-fault state: P=${present}, W=${write}, U=${user}, RSVD=${reserved_write}, I=${instruction_fetch}"
    exit 1
fi

if [[ "$fault_rip" != 0xffffffff8* ]]; then
    print -u2 "page-fault check: expected the faulting RIP inside the higher-half kernel, got ${fault_rip}"
    exit 1
fi

if [[ "$actual_output" == *"PF:UNEXPECTED-RETURN"* ]]; then
    print -u2 "page-fault check: diagnostic handler unexpectedly returned to the faulting instruction"
    exit 1
fi

print "page-fault check passed: vector 14 reached C with CR2 and error-code evidence"
print "page-fault state: CR2=${fault_address}, error=${error_code}, RIP=${fault_rip}"
print "page-fault decode: P=${present}, W=${write}, U=${user}, RSVD=${reserved_write}, I=${instruction_fetch}"
