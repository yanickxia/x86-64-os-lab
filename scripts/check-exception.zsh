#!/bin/zsh

set -eu

disk_image="$1"
kernel_elf="$2"
expected_output="${3:-HelloPTLKCUR}"
monitor_socket="build/exception-monitor-${$}.sock"
output_file="build/exception-debugcon-${$}.log"
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

symbols="$(x86_64-elf-nm -n "$kernel_elf")"
disassembly="$(x86_64-elf-objdump -d "$kernel_elf")"
idt_address="$(print -r -- "$symbols" | awk '$3 == "lesson_idt" { print $1; exit }')"

if [[ -z "$idt_address" || "$symbols" != *" T isr_invalid_opcode"* || \
      "$symbols" != *" T invalid_opcode_handler"* ]]; then
    print -u2 "exception check: expected lesson_idt, isr_invalid_opcode, and invalid_opcode_handler symbols"
    exit 1
fi

if [[ "$disassembly" != *"ud2"* || "$disassembly" != *"iretq"* ]]; then
    print -u2 "exception check: expected a deliberate UD2 trigger and an IRETQ return path"
    exit 1
fi

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

for attempt in {1..30}; do
    if [[ -S "$monitor_socket" && -f "$output_file" && "$(< "$output_file")" == "$expected_output" ]]; then
        break
    fi
    sleep 0.1
done

if [[ ! -S "$monitor_socket" ]]; then
    print -u2 "exception check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
monitor_output="$(printf 'info registers\nquit\n' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""
failed=0
actual_idt_base="missing"
actual_idt_limit="missing"
actual_rip="missing"

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    if [[ "$line" == RIP=* ]]; then
        fields=(${(z)line})
        actual_rip="${fields[1]#RIP=}"
    fi
    if [[ "$line" == IDT=* ]]; then
        fields=(${(z)line})
        actual_idt_base="${fields[2]:-missing}"
        actual_idt_limit="${fields[3]:-missing}"
        break
    fi
done

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "exception check: #UD reached the C handler but did not resume"
    print -u2 "exception check: expected '${expected_output}', got '${actual_output}'"
    print -u2 "exception check: advance the saved RIP past the two-byte UD2 in kernel/interrupts.c"
    failed=1
fi

if [[ "$monitor_output" != *"RIP=000000000001000e"* ]]; then
    print -u2 "exception check: expected execution to return and park at RIP=0x1000e"
    print -u2 "exception check: actual RIP=0x${actual_rip}"
    failed=1
fi

if [[ "$actual_idt_base" != "$idt_address" || "$actual_idt_limit" != "0000006f" ]]; then
    print -u2 "exception check: expected IDTR base=0x${idt_address} limit=0x006f"
    print -u2 "exception check: actual IDTR base=0x${actual_idt_base} limit=0x${actual_idt_limit}"
    failed=1
fi

if (( failed )); then
    exit 1
fi

print "exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e"
print "exception state: IDTR base=0x${idt_address} limit=0x006f, output='${actual_output}'"
