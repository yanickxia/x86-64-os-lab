#!/bin/zsh

set -eu

disk_image="$1"
boot_bin="$2"
kernel_bin="$3"
expected_size=$((2880 * 512))
actual_size="$(wc -c < "$disk_image" | tr -d ' ')"

if [[ "$actual_size" != "$expected_size" ]]; then
    print -u2 "disk image check: expected ${expected_size} bytes, got ${actual_size}"
    exit 1
fi

if ! cmp -s "$boot_bin" <(dd if="$disk_image" bs=512 count=1 status=none); then
    print -u2 "disk image check: sector 1 does not match build/boot.bin"
    exit 1
fi

if ! cmp -s "$kernel_bin" <(dd if="$disk_image" bs=512 skip=1 count=1 status=none); then
    print -u2 "disk image check: sector 2 does not match build/kernel.bin"
    exit 1
fi

print "disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1"
xxd -g 1 -s 512 -l 16 "$disk_image"
