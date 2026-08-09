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
	-drive if=floppy,format=raw,readonly=on,file=$(BOOT_BIN)

.PHONY: check-tools qemu-reset inspect-reset boot check-boot qemu-boot inspect-boot check-debugcon run-debugcon disassemble-boot inspect-message inspect-gdt inspect-protected inspect-long-mode check-segments check-call check-a20 check-gdt check-protected check-page-tables check-long-mode

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

boot: $(BOOT_BIN)

check-boot: boot
	@zsh scripts/check-boot-sector.zsh $(BOOT_BIN)

qemu-boot: check-boot
	@printf "QEMU is paused at reset; press Ctrl-C after inspection to stop it.\n"
	@qemu-system-x86_64 $(QEMU_BOOT_FLAGS)

inspect-boot:
	@mkdir -p build
	@x86_64-elf-gdb -q -x gdb/boot.gdb

check-debugcon: check-boot
	@zsh scripts/check-debugcon.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)

run-debugcon: check-boot
	@printf "Debug console output follows; press Ctrl-C to stop QEMU.\n"
	@qemu-system-x86_64 \
		-machine pc \
		-accel tcg \
		-display none \
		-serial none \
		-monitor none \
		-no-reboot \
		-boot order=a \
		-drive if=floppy,format=raw,readonly=on,file=$(BOOT_BIN) \
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

check-segments: check-boot
	@zsh scripts/check-segments.zsh $(BOOT_BIN)

check-call: check-boot
	@zsh scripts/check-call.zsh $(BOOT_BIN)

check-a20: check-boot
	@zsh scripts/check-a20.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)

check-gdt: check-boot
	@zsh scripts/check-gdt.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)

check-protected: check-boot
	@zsh scripts/check-protected.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)

check-page-tables: check-boot
	@zsh scripts/check-page-tables.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)

check-long-mode: check-boot
	@zsh scripts/check-long-mode.zsh $(BOOT_BIN) $(DEBUGCON_EXPECTED)
