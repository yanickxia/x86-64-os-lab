SHELL := /bin/zsh

TOOLS := \
	qemu-system-x86_64 \
	nasm \
	mcopy \
	x86_64-elf-gcc \
	x86_64-elf-ld \
	x86_64-elf-objdump \
	x86_64-elf-gdb

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
DEBUGCON_EXPECTED := Hello

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

.PHONY: check-tools qemu-reset inspect-reset boot check-boot qemu-boot inspect-boot check-debugcon run-debugcon disassemble-boot inspect-message check-segments check-call

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
	@ndisasm -b 16 -o 0x7c00 $(BOOT_BIN) | head -n 32

inspect-message: boot
	@xxd -g 1 -s 0x40 -l 7 $(BOOT_BIN)

check-segments: check-boot
	@zsh scripts/check-segments.zsh $(BOOT_BIN)

check-call: check-boot
	@zsh scripts/check-call.zsh $(BOOT_BIN)
