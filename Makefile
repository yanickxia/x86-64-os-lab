SHELL := /bin/zsh

TOOLS := \
	qemu-system-x86_64 \
	nasm \
	mcopy \
	x86_64-elf-gcc \
	x86_64-elf-ld \
	x86_64-elf-objcopy \
	x86_64-elf-objdump \
	x86_64-elf-readelf \
	x86_64-elf-nm \
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
KERNEL_C_SRCS := kernel/main.c kernel/interrupts.c
KERNEL_HEADERS := kernel/interrupts.h
KERNEL_LINKER := kernel/linker.ld
KERNEL_OBJ := build/kernel.o
KERNEL_C_OBJS := build/main.o build/interrupts.o
KERNEL_OBJS := $(KERNEL_OBJ) $(KERNEL_C_OBJS)
KERNEL_ELF := build/kernel.elf
KERNEL_BIN := build/kernel.bin
OS_IMAGE := build/os.img
FLOPPY_SECTORS := 2880

KERNEL_CFLAGS := \
	-std=c11 \
	-O2 \
	-g \
	-Wall \
	-Wextra \
	-Werror \
	-ffreestanding \
	-fno-builtin \
	-fno-stack-protector \
	-fno-pic \
	-fno-pie \
	-fno-asynchronous-unwind-tables \
	-fno-unwind-tables \
	-m64 \
	-mno-red-zone \
	-mno-mmx \
	-mno-sse \
	-mno-sse2

# Full debug-console output, asserted for exact equality.
DEBUGCON_EXPECTED := HelloPTLKCUR
# Lesson 18 proves the assembly-to-C boundary. Later C code may append output,
# so its check asserts this synchronization prefix rather than exact equality.
C_KERNEL_EXPECTED_PREFIX := HelloPTLKC
# Lesson 13 only proves that the boot path reached the payload. Later payload
# code may append output, so this remains a synchronization prefix.
KERNEL_ENTRY_EXPECTED := HelloPTLK
# Prefix that only means "the boot-sector switch sequence finished". Checks for
# earlier lessons use it purely to synchronize before querying machine state,
# so appending a new character in a later lesson must not turn them red.
BOOT_SYNC_PREFIX := HelloPTL

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

.PHONY: check-tools qemu-reset inspect-reset boot kernel-elf image check-boot check-image qemu-boot inspect-boot check-debugcon run-debugcon disassemble-boot disassemble-kernel inspect-kernel-elf inspect-kernel-c inspect-exception inspect-image inspect-message inspect-gdt inspect-protected inspect-long-mode check-segments check-call check-a20 check-gdt check-protected check-page-tables check-long-mode check-kernel-load check-kernel-entry check-kernel-elf check-c-kernel check-exception

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

$(KERNEL_OBJ): $(KERNEL_SRC)
	@mkdir -p build
	@nasm -f elf64 -g -F dwarf -o $@ $<

$(KERNEL_C_OBJS): build/%.o: kernel/%.c $(KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(KERNEL_CFLAGS) -c -o $@ $<

$(KERNEL_ELF): $(KERNEL_OBJS) $(KERNEL_LINKER)
	@x86_64-elf-ld -nostdlib -T $(KERNEL_LINKER) -o $@ $(KERNEL_OBJS)

$(KERNEL_BIN): $(KERNEL_ELF)
	@x86_64-elf-objcopy -O binary $< $@

$(OS_IMAGE): $(BOOT_BIN) $(KERNEL_BIN)
	@dd if=/dev/zero of=$@ bs=512 count=$(FLOPPY_SECTORS) status=none
	@dd if=$(BOOT_BIN) of=$@ conv=notrunc status=none
	@dd if=$(KERNEL_BIN) of=$@ bs=512 seek=1 conv=notrunc status=none

boot: $(BOOT_BIN)

kernel-elf: $(KERNEL_ELF)

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
	@printf '%s\n' '== 64-bit long-mode entry and payload handoff (0x7d30-0x7d4f) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x130 count=0x20 status=none | ndisasm -w -b 64 -o 0x7d30 -
	@printf '%s\n' '== 16-bit BIOS disk loader (from 0x7d50) =='
	@dd if=$(BOOT_BIN) bs=1 skip=0x150 count=0x30 status=none | ndisasm -w -b 16 -o 0x7d50 -

disassemble-kernel: $(KERNEL_BIN)
	@printf '%s\n' '== linked kernel disassembly (assembly entry + C) =='
	@x86_64-elf-objdump -d --start-address=0x10000 --stop-address=0x10040 $(KERNEL_ELF)
	@printf '%s\n' '== KERNEL64 magic data at raw offset 2 =='
	@xxd -g 1 -s 2 -l 8 $(KERNEL_BIN)

inspect-kernel-elf: $(KERNEL_ELF)
	@printf '%s\n' '== ELF header =='
	@x86_64-elf-readelf -h $(KERNEL_ELF)
	@printf '%s\n' '== linked symbols =='
	@x86_64-elf-nm -n $(KERNEL_ELF)
	@printf '%s\n' '== section headers =='
	@x86_64-elf-objdump -h $(KERNEL_ELF)

inspect-kernel-c: $(KERNEL_ELF)
	@printf '%s\n' '== assembly-to-C call site =='
	@x86_64-elf-objdump -d --disassemble=kernel_call_stub $(KERNEL_ELF)
	@printf '%s\n' '== kernel_main C source and target instructions =='
	@x86_64-elf-objdump -drS --disassemble=kernel_main $(KERNEL_ELF)
	@printf '%s\n' '== assembly debug_putc helper =='
	@x86_64-elf-objdump -d --disassemble=debug_putc $(KERNEL_ELF)

inspect-exception: $(KERNEL_ELF)
	@printf '%s\n' '== lesson IDT and exception symbols =='
	@x86_64-elf-nm -n $(KERNEL_ELF) | rg 'lesson_idt|isr_invalid_opcode|trigger_invalid_opcode|invalid_opcode_handler|exception_red_hang'
	@printf '%s\n' '== deliberate invalid-opcode trigger =='
	@x86_64-elf-objdump -d --disassemble=trigger_invalid_opcode $(KERNEL_ELF)
	@printf '%s\n' '== invalid-opcode assembly entry =='
	@x86_64-elf-objdump -d --disassemble=isr_invalid_opcode $(KERNEL_ELF)
	@printf '%s\n' '== invalid-opcode C policy =='
	@x86_64-elf-objdump -drS --disassemble=invalid_opcode_handler $(KERNEL_ELF)

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
	@zsh scripts/check-a20.zsh $(OS_IMAGE) $(BOOT_SYNC_PREFIX)

check-gdt: check-image
	@zsh scripts/check-gdt.zsh $(OS_IMAGE) $(BOOT_SYNC_PREFIX)

check-protected: check-image
	@zsh scripts/check-protected.zsh $(OS_IMAGE) $(BOOT_SYNC_PREFIX)

check-page-tables: check-image
	@zsh scripts/check-page-tables.zsh $(OS_IMAGE) $(BOOT_SYNC_PREFIX)

check-long-mode: check-image
	@zsh scripts/check-long-mode.zsh $(OS_IMAGE) $(BOOT_SYNC_PREFIX)

check-kernel-load: check-image $(KERNEL_BIN)
	@zsh scripts/check-kernel-load.zsh $(OS_IMAGE) $(KERNEL_BIN) $(BOOT_SYNC_PREFIX)

check-kernel-entry: check-image
	@zsh scripts/check-kernel-entry.zsh $(OS_IMAGE) $(KERNEL_ENTRY_EXPECTED)

check-kernel-elf: $(KERNEL_ELF) $(KERNEL_BIN)
	@zsh scripts/check-kernel-elf.zsh $(KERNEL_ELF) $(KERNEL_BIN)

check-c-kernel: check-image $(KERNEL_ELF)
	@zsh scripts/check-c-kernel.zsh $(OS_IMAGE) $(KERNEL_ELF) $(C_KERNEL_EXPECTED_PREFIX)

check-exception: check-image $(KERNEL_ELF)
	@zsh scripts/check-exception.zsh $(OS_IMAGE) $(KERNEL_ELF) $(DEBUGCON_EXPECTED)
