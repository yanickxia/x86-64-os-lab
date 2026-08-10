#!/bin/zsh

set -eu

kernel_elf="$1"
kernel_bin="$2"
expected_base="0000000000010000"
expected_entry="000000000001000a"
expected_hang="000000000001000e"
failed=0

header="$(x86_64-elf-readelf -h "$kernel_elf")"
symbols="$(x86_64-elf-nm -n "$kernel_elf")"
sections="$(x86_64-elf-objdump -h "$kernel_elf")"
actual_size="$(wc -c < "$kernel_bin" | tr -d ' ')"

if [[ "$header" != *"Class:                             ELF64"* || \
      "$header" != *"Type:                              EXEC"* || \
      "$header" != *"Machine:                           Advanced Micro Devices X86-64"* ]]; then
    print -u2 "kernel ELF check: expected an ELF64 x86-64 executable"
    print -u2 "kernel ELF check: actual ELF header:"
    print -u2 -- "$header"
    failed=1
fi

if [[ "$header" != *"Entry point address:               0x10000"* ]]; then
    actual_entry="$(print -r -- "$header" | sed -n 's/.*Entry point address:[[:space:]]*//p')"
    print -u2 "kernel ELF check: expected entry point 0x10000, got ${actual_entry:-unknown}"
    failed=1
fi

for expected_symbol in \
    "${expected_base} T kernel_start" \
    "0000000000010002 T kernel_magic" \
    "${expected_entry} T kernel_entry" \
    "${expected_hang} T kernel_hang"; do
    if [[ "$symbols" != *"$expected_symbol"* ]]; then
        print -u2 "kernel ELF check: expected symbol '${expected_symbol}'"
        failed=1
    fi
done

if [[ "$sections" != *".text"*"00000200"*"0000000000010000"* ]]; then
    print -u2 "kernel ELF check: expected .text VMA=0x10000 and size=0x200"
    failed=1
fi

if [[ "$actual_size" != "512" ]]; then
    print -u2 "kernel ELF check: expected raw kernel.bin size 512, got ${actual_size}"
    failed=1
fi

actual_prefix="$(xxd -p -l 16 "$kernel_bin")"
if [[ "$actual_prefix" != "eb084b45524e454c3634b04be6e9ebfe" ]]; then
    print -u2 "kernel ELF check: raw binary prefix changed, got ${actual_prefix}"
    failed=1
fi

if (( failed )); then
    print -u2 "kernel ELF check: actual symbols:"
    print -u2 -- "$symbols"
    print -u2 "kernel ELF check: actual sections:"
    print -u2 -- "$sections"
    exit 1
fi

print "kernel ELF check passed: ELF64 entry=0x10000, .text VMA=0x10000, raw payload=512 bytes"
print -- "$symbols"
