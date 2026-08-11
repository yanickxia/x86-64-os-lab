#!/bin/zsh

set -eu

disk_image="$1"
boot_bin="$2"
kernel_bin="$3"
stage2_bin="${4:-}"
stage2_lba="${5:-}"
kernel_load_elf="${6:-}"
kernel_load_elf_lba="${7:-}"
expected_size=$((2880 * 512))
actual_size="$(wc -c < "$disk_image" | tr -d ' ')"
kernel_size="$(wc -c < "$kernel_bin" | tr -d ' ')"
kernel_sectors=$((kernel_size / 512))

if [[ "$actual_size" != "$expected_size" ]]; then
    print -u2 "disk image check: expected ${expected_size} bytes, got ${actual_size}"
    exit 1
fi

if ! cmp -s "$boot_bin" <(dd if="$disk_image" bs=512 count=1 status=none); then
    print -u2 "disk image check: sector 1 does not match build/boot.bin"
    exit 1
fi

if (( kernel_size == 0 || kernel_size % 512 != 0 )); then
    print -u2 "disk image check: kernel payload must be a non-empty whole number of sectors, got ${kernel_size} bytes"
    exit 1
fi

if ! cmp -s "$kernel_bin" <(dd if="$disk_image" bs=512 skip=1 count="$kernel_sectors" status=none); then
    print -u2 "disk image check: ${kernel_sectors}-sector payload at LBA 1 does not match build/kernel.bin"
    exit 1
fi

print "disk image check passed: 1.44 MiB image, boot sector at LBA 0, ${kernel_sectors}-sector kernel payload at LBA 1"

if [[ -n "$stage2_bin" ]]; then
    stage2_size="$(wc -c < "$stage2_bin" | tr -d ' ')"
    stage2_sectors=$((stage2_size / 512))
    if (( stage2_size == 0 || stage2_size % 512 != 0 )); then
        print -u2 "disk image check: stage 2 must be a non-empty whole number of sectors, got ${stage2_size} bytes"
        exit 1
    fi
    if ! cmp -s "$stage2_bin" <(dd if="$disk_image" bs=512 skip="$stage2_lba" count="$stage2_sectors" status=none); then
        print -u2 "disk image check: ${stage2_sectors}-sector stage 2 at LBA ${stage2_lba} does not match build/stage2.bin"
        exit 1
    fi
    print "disk image check: ${stage2_sectors}-sector stage 2 is present at LBA ${stage2_lba}"
fi

if [[ -n "$kernel_load_elf" ]]; then
    kernel_load_elf_size="$(wc -c < "$kernel_load_elf" | tr -d ' ')"
    if ! cmp -s "$kernel_load_elf" <(dd if="$disk_image" bs=1 skip="$((kernel_load_elf_lba * 512))" count="$kernel_load_elf_size" status=none); then
        print -u2 "disk image check: loader-facing ELF at LBA ${kernel_load_elf_lba} does not match ${kernel_load_elf}"
        exit 1
    fi
    print "disk image check: ${kernel_load_elf_size}-byte ELF image is present at LBA ${kernel_load_elf_lba}"
fi

xxd -g 1 -s 512 -l 16 "$disk_image"
