#!/bin/zsh

set -eu

boot_bin="$1"
actual_size="$(wc -c < "$boot_bin" | tr -d ' ')"

if [[ "$actual_size" != "512" ]]; then
    print -u2 "boot sector size: expected 512 bytes, got ${actual_size}"
    exit 1
fi

actual_signature="$(xxd -p -s 510 -l 2 "$boot_bin")"

if [[ "$actual_signature" != "55aa" ]]; then
    print -u2 "boot signature: expected 55aa at offsets 510-511, got ${actual_signature}"
    exit 1
fi

print "boot sector check passed: 512 bytes, signature 55aa"
xxd -g 1 -s 496 -l 16 "$boot_bin"

