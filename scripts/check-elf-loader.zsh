#!/bin/zsh

set -eu

disk_image="$1"
kernel_elf="$2"
kernel_bin="$3"
expected_output="${4:-HelloPTLKCUR}"
test_image="$(mktemp build/elf-loader-image.XXXXXX)"
monitor_socket="build/elf-loader-monitor-${$}.sock"
output_file="build/elf-loader-debugcon-${$}.log"
qemu_pid=""

cleanup() {
    if [[ -n "$qemu_pid" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
        qemu_pid=""
    fi
    [[ -S "$monitor_socket" ]] && unlink "$monitor_socket" 2>/dev/null || true
    [[ -f "$output_file" ]] && unlink "$output_file" 2>/dev/null || true
    [[ -f "$test_image" ]] && unlink "$test_image" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

program_headers="$(x86_64-elf-readelf -lW "$kernel_elf")"
if ! print -r -- "$program_headers" | awk '$1 == "LOAD" && $5 == "0x000000" && $6 != "0x000000" { found = 1 } END { exit !found }'; then
    print -u2 "ELF loader check: expected a PT_LOAD with p_filesz=0 and non-zero p_memsz for .bss"
    exit 1
fi

symbol_address() {
    local symbol="$1"
    local address
    address="$(x86_64-elf-nm -n "$kernel_elf" | awk -v symbol="$symbol" '$3 == symbol { print "0x" $1; exit }')"
    if [[ -z "$address" ]]; then
        print -u2 "ELF loader check: missing symbol ${symbol}"
        exit 1
    fi
    print -r -- "$address"
}

bss_probe_address="$(symbol_address lesson23_bss_probe)"
stack_bottom="$(symbol_address kernel_stack_bottom)"
stack_top="$(symbol_address kernel_stack_top)"

# Destroy the historical raw payload at LBA 1 in a temporary image. A successful
# boot now proves that stage 2 consumed the ELF at LBA 18 instead of those bytes.
cp "$disk_image" "$test_image"
dd if=/dev/zero of="$test_image" bs=512 seek=1 count=4 conv=notrunc status=none

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
    -drive if=floppy,format=raw,readonly=on,file="$test_image" \
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
    print -u2 "ELF loader check: QEMU did not create the monitor socket"
    exit 1
fi

actual_output="$(< "$output_file")"
monitor_output="$(printf '%s\n' \
    'xp /1wx 0x20000' \
    'xp /1gx 0x5018' \
    "xp /1gx ${bss_probe_address}" \
    'xp /1gx 0x7018' \
    'info registers' \
    'quit' | socat - "UNIX-CONNECT:$monitor_socket")"
qemu_pid=""

address_label() {
    printf '%08x' "$(( $1 ))"
}

scratch_label="$(address_label 0x20000)"
entry_label="$(address_label 0x5018)"
bss_label="$(address_label "$bss_probe_address")"
ack_label="$(address_label 0x7018)"
actual_scratch="missing"
actual_entry="missing"
actual_bss="missing"
actual_ack="missing"
register_line=""

for line in ${(f)monitor_output}; do
    line="${line%$'\r'}"
    case "$line" in
        ${scratch_label}:*) actual_scratch="${line##* }" ;;
        ${entry_label}:*) actual_entry="${line##* }" ;;
        ${bss_label}:*) actual_bss="${line##* }" ;;
        ${ack_label}:*) actual_ack="${line##* }" ;;
        *RSP=*) register_line="$line" ;;
    esac
done

if [[ "$actual_output" != "$expected_output" ]]; then
    print -u2 "ELF loader check: expected '${expected_output}' after corrupting raw LBA 1, got '${actual_output}'"
    print -u2 "ELF loader check: the boot path must come from the ELF image at LBA 18"
    exit 1
fi

if [[ "$actual_scratch" != "0x464c457f" ]]; then
    print -u2 "ELF loader check: ELF magic was not read into scratch address 0x20000"
    print -u2 "ELF loader check: actual ${actual_scratch}"
    exit 1
fi

expected_entry="0x0000000000010000"
if [[ "$actual_entry" != "$expected_entry" ]]; then
    print -u2 "ELF loader check: boot_info.kernel_entry_phys should come from ELF e_entry"
    print -u2 "ELF loader check: expected ${expected_entry}, got ${actual_entry}"
    exit 1
fi

expected_ack="0x214b4f3436464c45"
if [[ "$actual_bss" != "0x0000000000000000" ]]; then
    print -u2 "ELF loader check: PT_LOAD file bytes reached C, but the NOBITS probe is ${actual_bss}"
    print -u2 "ELF loader check: zero exactly p_memsz - p_filesz bytes at the lesson-23 TODO"
    print -u2 "ELF loader check: C environment acknowledgement remains ${actual_ack} at 0x7018"
    exit 1
fi

if [[ "$actual_ack" != "$expected_ack" ]]; then
    print -u2 "ELF loader check: .bss is zero, but C did not acknowledge the ELF/stack environment"
    print -u2 "ELF loader check: expected ${expected_ack} at 0x7018, got ${actual_ack}"
    exit 1
fi

actual_rsp="$(print -r -- "$register_line" | sed -E 's/.*RSP=([0-9A-Fa-f]+).*/0x\1/')"
if [[ "$actual_rsp" == "$register_line" || -z "$actual_rsp" ]]; then
    print -u2 "ELF loader check: could not parse RSP from QEMU monitor"
    exit 1
fi

if (( actual_rsp != stack_top )); then
    print -u2 "ELF loader check: expected the returned kernel stack at ${stack_top}, got ${actual_rsp}"
    exit 1
fi

kernel_size="$(wc -c < "$kernel_bin" | tr -d ' ')"
print "ELF loader check passed: corrupted raw LBA 1 was ignored; stage 2 loaded ${kernel_size} file bytes from PT_LOAD"
print "ELF state: entry=${actual_entry}, bss_probe=${actual_bss}, stack=${stack_bottom}..${stack_top}, RSP=${actual_rsp}, C_ack=${actual_ack}"
