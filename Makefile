SHELL := /bin/zsh

TOOLS := \
	qemu-system-x86_64 \
	nasm \
	mcopy \
	x86_64-elf-gcc \
	x86_64-elf-ld \
	x86_64-elf-objdump \
	x86_64-elf-gdb \
	socat

QEMU_RESET_FLAGS := \
	-machine pc \
	-accel tcg \
	-S \
	-gdb tcp::1234 \
	-display none \
	-serial none \
	-monitor none \
	-no-reboot \
	-no-shutdown

BOOT_SRC := boot/boot.asm
BOOT_BIN := build/boot.bin
KERNEL_SRC := kernel/payload.asm
KERNEL_BIN := build/kernel.bin
OS_IMAGE := build/os.img
FLOPPY_SECTORS := 2880
DEBUGCON_EXPECTED := HelloPTL

QEMU_BOOT_FLAGS := \
	-machine pc \
	-accel tcg \
	-S \
	-gdb tcp::1234 \
	-display none \
	-serial none \
	-monitor none \
	-no-reboot \
	-no-shutdown \
	-boot order=a \
	-drive if=floppy,format=raw,readonly=on,file=$(OS_IMAGE)

.PHONY: check-tools qemu-reset inspect-reset boot image check-boot check-image qemu-boot inspect-boot check-debugcon run-debugcon disassemble-boot disassemble-kernel inspect-image inspect-message inspect-gdt inspect-protected inspect-long-mode check-segments check-call check-a20 check-gdt check-protected check-page-tables check-long-mode check-kernel-load

check-tools:
	@set -e; \
	for tool in $(TOOLS); do \
		command -v "$$tool" >/dev/null; \
		printf "%-24s %s\n" "$$tool" "$$(command -v "$$tool")"; \
	done
	@printf "host architecture:        "
	@uname -m
	@printf "compiler target:          "
	@x86_64-elf-gcc -dumpmachine
	@test "$$(x86_64-elf-gcc -dumpmachine)" = "x86_64-elf"
	@printf "toolchain check passed\n"

qemu-reset:
	@printf "QEMU is paused before its first instruction; press Ctrl-C to stop it.\n"
	@qemu-system-x86_64 $(QEMU_RESET_FLAGS)

inspect-reset:
	@mkdir -p build
	@x86_64-elf-gdb -q -x gdb/reset.gdb

$(BOOT_BIN): $(BOOT_SRC)
	@mkdir -p build
	@nasm -f bin -o $@ $<

$(KERNEL_BIN): $(KERNEL_SRC)
	@mkdir -p build
	@nasm -f bin -o $@ $<

$(OS_IMAGE): $(BOOT_BIN) $(KERNEL_BIN)
	@dd if=/dev/zero of=$@ bs=512 count=$(FLOPPY_SECTORS) status=none
	@dd if=$(BOOT_BIN) of=$@ conv=notrunc status=none
	@dd if=$(KERNEL_BIN) of=$@ bs=512 seek=1 conv=notrunc status=none

boot: $(BOOT_BIN)

image: $(OS_IMAGE)

check-boot: boot
	@zsh scripts/check-boot-sector.zsh $(BOOT_BIN)

check-image: image check-boot
	@zsh scripts/check-disk-image.zsh $(OS_IMAGE) $(BOOT_BIN) $(KERNEL_BIN)

qemu-boot: check-image
	@printf "QEMU is paused at reset; press Ctrl-C after inspection to stop it.\n"
	@qemu-system-x86_64 $(QEMU_BOOT_FLAGS)

inspect-boot:
	@mkdir -p build
	@x86_64-elf-gdb -q -x gdb/boot.gdb

check-debugcon: check-image
	@zsh scripts/check-debugcon.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

run-debugcon: check-image
	@printf "Debug console output follows; press Ctrl-C to stop QEMU.\n"
	@qemu-system-x86_64 \
		-machine pc \
		-accel tcg \
		-display none \
		-serial none \
		-monitor none \
		-no-reboot \
		-boot order=a \
		-drive if=floppy,format=raw,readonly=on,file=$(OS_IMAGE) \
		-chardev stdio,id=debugcon,signal=off \
		-device isa-debugcon,iobase=0xe9,chardev=debugcon

disassemble-boot: boot
	@printf '%s\n' '== 16-bit startup and real-mode path (0x7c00-0x7c32) =='
	@dd if=$(BOOT_BIN) bs=1 count=0x33 status=none | ndisasm -w -b 16 -o 0x7c00 -
	@printf '%s\n' '== 16-bit protected-mode switch (0x7c70-0x7c81) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x70 count=0x12 status=none | ndisasm -w -b 16 -o 0x7c70 -
	@printf '%s\n' '== 32-bit protected-mode entry (0x7c90-0x7caf) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x90 count=0x20 status=none | ndisasm -w -b 32 -o 0x7c90 -
	@printf '%s\n' '== 32-bit page-table setup (from 0x7cb0) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0xb0 count=0x2e status=none | ndisasm -w -b 32 -o 0x7cb0 -
	@printf '%s\n' '== 32-bit long-mode switch (0x7cf0-0x7d20) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0xf0 count=0x31 status=none | ndisasm -w -b 32 -o 0x7cf0 -
	@printf '%s\n' '== 64-bit long-mode entry (from 0x7d30) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x130 count=0x06 status=none | ndisasm -w -b 64 -o 0x7d30 -
	@printf '%s\n' '== 16-bit BIOS disk loader (from 0x7d50) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x150 count=0x30 status=none | ndisasm -w -b 16 -o 0x7d50 -

disassemble-kernel: $(KERNEL_BIN)
	@ndisasm -w -b 64 -o 0x10000 $(KERNEL_BIN) | sed -n '1,8p'

inspect-image: image
	@printf '%s\n' '== boot signature and start of sector 2 =='
	@xxd -g 1 -s 0x1f0 -l 48 $(OS_IMAGE)

inspect-message: boot
	@xxd -g 1 -s 0x40 -l 7 $(BOOT_BIN)

inspect-gdt: boot
	@printf '%s\n' '== four GDT entries at 0x7c50 =='
	@xxd -g 1 -s 0x50 -l 32 $(BOOT_BIN)
	@printf '%s\n' '== GDTR pseudo-descriptor at 0x7ce0 =='
	@xxd -g 1 -s 0xe0 -l 6 $(BOOT_BIN)

inspect-protected: boot
	@xxd -g 1 -s 0x70 -l 64 $(BOOT_BIN)

inspect-long-mode: boot
	@xxd -g 1 -s 0xf0 -l 70 $(BOOT_BIN)

check-segments: check-image
	@zsh scripts/check-segments.zsh $(OS_IMAGE)

check-call: check-image
	@zsh scripts/check-call.zsh $(OS_IMAGE)

check-a20: check-image
	@zsh scripts/check-a20.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-gdt: check-image
	@zsh scripts/check-gdt.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-protected: check-image
	@zsh scripts/check-protected.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-page-tables: check-image
	@zsh scripts/check-page-tables.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-long-mode: check-image
	@zsh scripts/check-long-mode.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-kernel-load: check-image
	@zsh scripts/check-kernel-load.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)
