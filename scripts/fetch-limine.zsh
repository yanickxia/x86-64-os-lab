#!/bin/zsh

set -eu

project_root="${0:A:h:h}"
dependency_root="${project_root}/build/limine"
binary_archive="${dependency_root}/limine-binary-12.5.2.tar.xz"
binary_root="${dependency_root}/limine-binary"
header_root="${dependency_root}/include"
header_path="${header_root}/limine.h"

binary_url="https://github.com/Limine-Bootloader/Limine/releases/download/v12.5.2/limine-binary.tar.xz"
binary_sha256="5e2d6eb86623fcdcd2a873c9eca7dcafccb34182c17779535fe824fd57b688c5"
header_url="https://raw.githubusercontent.com/Limine-Bootloader/limine-protocol/4e1587972c148d43b2f397e4e5983bdd6c2a55a0/include/limine.h"
header_sha256="4de542d1c232b230ca4af04c5b89a78f51c9bdacb928a94ac44fc88377208a63"

mkdir -p "$dependency_root" "$header_root"

if [[ ! -f "$binary_archive" ]] || [[ "$(shasum -a 256 "$binary_archive" | awk '{print $1}')" != "$binary_sha256" ]]; then
    curl --fail --location --silent --show-error "$binary_url" --output "${binary_archive}.tmp"
    mv "${binary_archive}.tmp" "$binary_archive"
fi

actual_binary_sha256="$(shasum -a 256 "$binary_archive" | awk '{print $1}')"
if [[ "$actual_binary_sha256" != "$binary_sha256" ]]; then
    print -u2 "Limine binary checksum mismatch: expected ${binary_sha256}, got ${actual_binary_sha256}"
    exit 1
fi

if [[ ! -f "${binary_root}/BOOTX64.EFI" ]]; then
    tar -xJf "$binary_archive" -C "$dependency_root"
fi

if [[ ! -f "$header_path" ]] || [[ "$(shasum -a 256 "$header_path" | awk '{print $1}')" != "$header_sha256" ]]; then
    curl --fail --location --silent --show-error "$header_url" --output "${header_path}.tmp"
    mv "${header_path}.tmp" "$header_path"
fi

actual_header_sha256="$(shasum -a 256 "$header_path" | awk '{print $1}')"
if [[ "$actual_header_sha256" != "$header_sha256" ]]; then
    print -u2 "Limine protocol header checksum mismatch: expected ${header_sha256}, got ${actual_header_sha256}"
    exit 1
fi

print "Limine dependencies ready: bootloader v12.5.2, protocol 4e1587972c14"
