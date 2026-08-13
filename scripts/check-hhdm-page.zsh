#!/bin/zsh

set -eu

disk_image="$1"
ovmf_code="$2"
output_file="build/hhdm-page-${$}.log"
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
    [[ "$actual_output" == *"HHDM:PAGE:OK"* ]] && break
    if (( attempt > 20 )) && [[ "$actual_output" == *"HHDM:RESPONSE:FAIL"* ||
        "$actual_output" == *"HHDM:POISON:FAIL"* || "$actual_output" == *"HHDM:PREPARE:FAIL"* ||
        "$actual_output" == *"HHDM:ZERO:FAIL"* ]]; then
        break
    fi
    sleep 0.1
done

actual_output="$(< "$output_file")"
cleanup
trap - EXIT INT TERM

if [[ "$actual_output" != *"PMM:OK"* ]]; then
    print -u2 "hhdm-page check: prerequisite physical-page ownership evidence is missing"
    print -u2 "hhdm-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"HHDM:RESPONSE:OK"* ]]; then
    print -u2 "hhdm-page check: Limine did not provide the requested HHDM response"
    print -u2 "hhdm-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if [[ "$actual_output" != *"HHDM:PAGE:OK"* ]]; then
    print -u2 "hhdm-page check: HHDM exists, but the allocated frame was not translated and cleared"
    print -u2 "hhdm-page check: complete hhdm_prepare_page() in kernel/hhdm.c"
    print -u2 "hhdm-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

read_value() {
    local key="$1"
    print -r -- "$actual_output" | sed -n "s/^${key}=\(0x[0-9a-f]\{16\}\)$/\1/p" | head -1
}

hhdm_offset="$(read_value 'HHDM:OFFSET')"
physical_address="$(read_value 'HHDM:PA')"
virtual_address="$(read_value 'HHDM:VA')"
before_first="$(read_value 'HHDM:BEFORE-FIRST')"
before_last="$(read_value 'HHDM:BEFORE-LAST')"
after_first="$(read_value 'HHDM:AFTER-FIRST')"
after_last="$(read_value 'HHDM:AFTER-LAST')"

if [[ -z "$hhdm_offset" || -z "$physical_address" || -z "$virtual_address" || -z "$before_first" ||
    -z "$before_last" || -z "$after_first" || -z "$after_last" ]]; then
    print -u2 "hhdm-page check: address or page-content evidence is incomplete"
    print -u2 "hhdm-page output: ${actual_output//$'\n'/ | }"
    exit 1
fi

if ! python3 - "$hhdm_offset" "$physical_address" "$virtual_address" <<'PY'
import sys

offset, physical, virtual = (int(value, 16) for value in sys.argv[1:])
if physical % 4096 != 0:
    print("hhdm-page check: allocated PA is not 4 KiB aligned", file=sys.stderr)
    raise SystemExit(1)
if offset + physical > (1 << 64) - 1:
    print("hhdm-page check: HHDM address addition overflowed", file=sys.stderr)
    raise SystemExit(1)
if virtual != offset + physical:
    print(
        f"hhdm-page check: expected VA=offset+PA={offset + physical:#018x}, got {virtual:#018x}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
then
    exit 1
fi

if [[ "$before_first" != "0xa5a55a5adeadbeef" || "$before_last" != "0xa5a55a5adeadbeef" ]]; then
    print -u2 "hhdm-page check: observer did not see the non-zero sentinel at both page boundaries"
    print -u2 "hhdm-page state: first=${before_first}, last=${before_last}"
    exit 1
fi

if [[ "$after_first" != "0x0000000000000000" || "$after_last" != "0x0000000000000000" ]]; then
    print -u2 "hhdm-page check: expected both page-boundary words to become zero"
    print -u2 "hhdm-page state: first=${after_first}, last=${after_last}"
    exit 1
fi

print "hhdm-page check passed: allocated PA became an HHDM VA and all 4096 bytes were cleared"
print "hhdm-page state: offset=${hhdm_offset}, PA=${physical_address}, VA=${virtual_address}"
print "hhdm-page contents: first/last ${before_first} -> ${after_first}"
