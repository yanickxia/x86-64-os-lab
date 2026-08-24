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
STAGE2_SRC := boot/stage2.asm
STAGE2_BIN := build/stage2.bin
STAGE2_SECTORS := 2
STAGE2_IMAGE_BYTES := 1024
STAGE2_LBA := 5
STAGE2_LOAD_SEGMENT := 0x0800
STAGE2_LOAD_ADDR := 0x8000
STAGE2_HANDSHAKE_ADDR := 0x7000
KERNEL_SRC := kernel/payload.asm
KERNEL_C_SRCS := kernel/main.c kernel/interrupts.c
KERNEL_HEADERS := kernel/interrupts.h kernel/boot_info.h
KERNEL_LINKER := kernel/linker.ld
KERNEL_OBJ := build/kernel.o
KERNEL_C_OBJS := build/main.o build/interrupts.o
KERNEL_OBJS := $(KERNEL_OBJ) $(KERNEL_C_OBJS)
KERNEL_ELF := build/kernel.elf
KERNEL_LOAD_ELF := build/kernel.load.elf
KERNEL_BIN := build/kernel.bin
KERNEL_SECTORS := 4
KERNEL_IMAGE_BYTES := 2048
KERNEL_LOAD_ELF_LBA := 18
KERNEL_LOAD_ELF_IMAGE_BYTES := 8192
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

LIMINE_VERSION := 12.5.2
LIMINE_PROTOCOL_COMMIT := 4e1587972c148d43b2f397e4e5983bdd6c2a55a0
LIMINE_DEPS_STAMP := build/limine/.deps-$(LIMINE_VERSION)-$(LIMINE_PROTOCOL_COMMIT)
LIMINE_HEADER := build/limine/include/limine.h
LIMINE_BOOT_EFI := build/limine/limine-binary/BOOTX64.EFI
LIMINE_KERNEL_SRC := kernel/limine_main.c
LIMINE_PMM_SRC := kernel/pmm.c
LIMINE_HHDM_SRC := kernel/hhdm.c
LIMINE_FAULTS_SRC := kernel/faults.c
LIMINE_FAULTS_ASM_SRC := kernel/faults_asm.asm
LIMINE_VMM_SRC := kernel/vmm.c
LIMINE_VMM_MAPPER_SRC := kernel/vmm_mapper.c
LIMINE_KERNEL_HEADERS := kernel/pmm.h kernel/hhdm.h kernel/faults.h kernel/vmm.h kernel/vmm_mapper.h
LIMINE_KERNEL_LINKER := kernel/limine_linker.ld
LIMINE_KERNEL_OBJ := build/limine-main.o
LIMINE_PMM_OBJ := build/limine-pmm.o
LIMINE_HHDM_OBJ := build/limine-hhdm.o
LIMINE_FAULTS_OBJ := build/limine-faults.o
LIMINE_FAULTS_ASM_OBJ := build/limine-faults-asm.o
LIMINE_VMM_OBJ := build/limine-vmm.o
LIMINE_VMM_MAPPER_OBJ := build/limine-vmm-mapper.o
LIMINE_KERNEL_OBJS := \
	$(LIMINE_KERNEL_OBJ) \
	$(LIMINE_PMM_OBJ) \
	$(LIMINE_HHDM_OBJ) \
	$(LIMINE_FAULTS_OBJ) \
	$(LIMINE_FAULTS_ASM_OBJ) \
	$(LIMINE_VMM_OBJ) \
	$(LIMINE_VMM_MAPPER_OBJ)
LIMINE_KERNEL_ELF := build/limine-kernel.elf
LIMINE_IMAGE := build/limine-os.img
LIMINE_CONFIG := limine.conf
OVMF_CODE ?= /opt/homebrew/share/qemu/edk2-x86_64-code.fd

LIMINE_CFLAGS := \
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
	-ffunction-sections \
	-fdata-sections \
	-m64 \
	-mcmodel=kernel \
	-mno-red-zone \
	-mno-mmx \
	-mno-sse \
	-mno-sse2

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

.PHONY: check-tools check-limine-tools qemu-reset inspect-reset
.PHONY: boot stage2 kernel-elf image qemu-boot
.PHONY: inspect-boot inspect-reset disassemble-boot disassemble-stage2 disassemble-kernel
.PHONY: inspect-kernel-elf inspect-kernel-c inspect-exception inspect-image inspect-kernel-span
.PHONY: inspect-stage2 inspect-boot-info inspect-elf-loader inspect-message inspect-gdt
.PHONY: inspect-protected inspect-long-mode
.PHONY: check-boot check-image check-debugcon run-debugcon check-segments check-call check-a20
.PHONY: check-gdt check-protected check-page-tables check-long-mode check-kernel-load
.PHONY: check-multisector-load check-stage2-handoff check-e820-boot-info check-elf-loader
.PHONY: check-kernel-entry check-kernel-elf check-c-kernel check-exception check-bootloader-graduation
.PHONY: limine-deps limine-kernel limine-image run-limine
.PHONY: inspect-limine-api inspect-limine-handoff inspect-physical-pages inspect-hhdm-page
.PHONY: inspect-page-fault inspect-kernel-page-table inspect-kernel-address-space
.PHONY: inspect-demand-page inspect-page-table-walk inspect-vmm-mapper
.PHONY: check-limine-handoff check-physical-pages check-hhdm-page check-page-fault
.PHONY: check-kernel-page-table check-kernel-address-space check-demand-page check-page-table-walk check-vmm-mapper

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

check-limine-tools:
	@set -e; \
	for tool in curl shasum mformat mmd mcopy python3 qemu-system-x86_64 \
		x86_64-elf-gcc x86_64-elf-ld x86_64-elf-readelf; do \
		command -v "$$tool" >/dev/null; \
	done
	@test -f $(OVMF_CODE)
	@printf "Limine/UEFI host tools check passed\n"

qemu-reset:
	@printf "QEMU is paused before its first instruction; press Ctrl-C to stop it.\n"
	@qemu-system-x86_64 $(QEMU_RESET_FLAGS)

inspect-reset:
	@mkdir -p build
	@x86_64-elf-gdb -q -x gdb/reset.gdb

$(BOOT_BIN): $(BOOT_SRC)
	@mkdir -p build
	@nasm \
		-D KERNEL_SECTORS=$(KERNEL_SECTORS) \
		-D STAGE2_SECTORS=$(STAGE2_SECTORS) \
		-D STAGE2_LOAD_SEGMENT=$(STAGE2_LOAD_SEGMENT) \
		-D STAGE2_LOAD_ADDR=$(STAGE2_LOAD_ADDR) \
		-f bin -o $@ $<

$(STAGE2_BIN): $(STAGE2_SRC)
	@mkdir -p build
	@nasm -D STAGE2_IMAGE_BYTES=$(STAGE2_IMAGE_BYTES) -f bin -o $@ $<

$(KERNEL_OBJ): $(KERNEL_SRC)
	@mkdir -p build
	@nasm -f elf64 -g -F dwarf -o $@ $<

$(KERNEL_C_OBJS): build/%.o: kernel/%.c $(KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(KERNEL_CFLAGS) -c -o $@ $<

$(KERNEL_ELF): $(KERNEL_OBJS) $(KERNEL_LINKER)
	@x86_64-elf-ld -nostdlib --no-warn-rwx-segments --defsym KERNEL_IMAGE_BYTES=$(KERNEL_IMAGE_BYTES) -T $(KERNEL_LINKER) -o $@ $(KERNEL_OBJS)

$(KERNEL_BIN): $(KERNEL_ELF)
	@x86_64-elf-objcopy -O binary $< $@

$(KERNEL_LOAD_ELF): $(KERNEL_ELF)
	@x86_64-elf-objcopy --strip-all $< $@
	@test "$$(wc -c < $@ | tr -d ' ')" -le $(KERNEL_LOAD_ELF_IMAGE_BYTES)

$(OS_IMAGE): $(BOOT_BIN) $(KERNEL_BIN) $(STAGE2_BIN) $(KERNEL_LOAD_ELF)
	@dd if=/dev/zero of=$@ bs=512 count=$(FLOPPY_SECTORS) status=none
	@dd if=$(BOOT_BIN) of=$@ conv=notrunc status=none
	@dd if=$(KERNEL_BIN) of=$@ bs=512 seek=1 conv=notrunc status=none
	@dd if=$(STAGE2_BIN) of=$@ bs=512 seek=$(STAGE2_LBA) conv=notrunc status=none
	@dd if=$(KERNEL_LOAD_ELF) of=$@ bs=512 seek=$(KERNEL_LOAD_ELF_LBA) conv=notrunc status=none
boot: $(BOOT_BIN)

stage2: $(STAGE2_BIN)

kernel-elf: $(KERNEL_ELF)

image: $(OS_IMAGE)

check-boot: boot
	@zsh scripts/check-boot-sector.zsh $(BOOT_BIN)

check-image: image check-boot
	@zsh scripts/check-disk-image.zsh $(OS_IMAGE) $(BOOT_BIN) $(KERNEL_BIN) $(STAGE2_BIN) $(STAGE2_LBA) $(KERNEL_LOAD_ELF) $(KERNEL_LOAD_ELF_LBA)

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

disassemble-stage2: stage2
	@printf '%s\n' '== stage 2 entry jump and six-byte magic =='
	@xxd -g 1 -l 8 $(STAGE2_BIN)
	@printf '%s\n' '== executable stage 2 entry at 0x8008 =='
	@dd if=$(STAGE2_BIN) bs=1 skip=8 count=20 status=none | ndisasm -b 16 -o 0x8008 -

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

inspect-kernel-span: image
	@printf '%s\n' '== kernel image size and last 16 bytes =='
	@wc -c $(KERNEL_BIN)
	@xxd -g 1 -s 0x7f0 -l 16 $(KERNEL_BIN)
	@printf '%s\n' '== same tail bytes inside os.img =='
	@xxd -g 1 -s 0x9f0 -l 16 $(OS_IMAGE)

inspect-stage2: image
	@printf '%s\n' '== stage 2 source image: entry and tail =='
	@wc -c $(STAGE2_BIN)
	@xxd -g 1 -l 24 $(STAGE2_BIN)
	@xxd -g 1 -s 0x3f0 -l 16 $(STAGE2_BIN)
	@printf '%s\n' '== same stage 2 bytes at os.img LBA 5 =='
	@xxd -g 1 -s 0xa00 -l 24 $(OS_IMAGE)
	@xxd -g 1 -s 0xdf0 -l 16 $(OS_IMAGE)

inspect-boot-info: $(STAGE2_BIN) $(KERNEL_ELF)
	@printf '%s\n' '== E820 query and boot_info publication in stage 2 =='
	@dd if=$(STAGE2_BIN) bs=1 skip=8 status=none | ndisasm -b 16 -o 0x8008 - | rg -n 'int 0x15|534d4150|5008|5020|ret' | head -24
	@printf '%s\n' '== C boot_info consumer =='
	@x86_64-elf-objdump -drS --disassemble=kernel_main $(KERNEL_ELF) | rg -C 3 '5000|7010|214b4f43|boot_info|entry_count|type'

inspect-elf-loader: $(STAGE2_BIN) $(KERNEL_ELF) $(KERNEL_LOAD_ELF)
	@printf '%s\n' '== ELF program headers consumed by stage 2 =='
	@x86_64-elf-readelf -lW $(KERNEL_LOAD_ELF)
	@printf '%s\n' '== ELF loader copy/poison/zero path =='
	@dd if=$(STAGE2_BIN) bs=1 skip=8 status=none | ndisasm -b 16 -o 0x8008 - | rg -n 'int 0x13|rep movsb|rep stosb|a5|7018|ret'
	@printf '%s\n' '== .bss and dedicated stack symbols =='
	@x86_64-elf-nm -n $(KERNEL_ELF) | rg '__bss_|lesson23_bss_probe|kernel_stack_(bottom|top)'

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

check-multisector-load: check-image $(KERNEL_BIN)
	@zsh scripts/check-multisector-load.zsh $(OS_IMAGE) $(KERNEL_BIN) $(KERNEL_SECTORS) $(DEBUGCON_EXPECTED)

check-stage2-handoff: check-image $(STAGE2_BIN)
	@zsh scripts/check-stage2-handoff.zsh $(OS_IMAGE) $(STAGE2_BIN) $(STAGE2_LOAD_ADDR) $(STAGE2_HANDSHAKE_ADDR) $(DEBUGCON_EXPECTED)

check-e820-boot-info: check-image $(STAGE2_BIN) $(KERNEL_ELF)
	@zsh scripts/check-e820-boot-info.zsh $(OS_IMAGE) $(DEBUGCON_EXPECTED)

check-elf-loader: check-image $(STAGE2_BIN) $(KERNEL_ELF) $(KERNEL_LOAD_ELF)
	@zsh scripts/check-elf-loader.zsh $(OS_IMAGE) $(KERNEL_ELF) $(KERNEL_BIN) $(DEBUGCON_EXPECTED)

check-kernel-entry: check-image
	@zsh scripts/check-kernel-entry.zsh $(OS_IMAGE) $(KERNEL_ENTRY_EXPECTED)

check-kernel-elf: $(KERNEL_ELF) $(KERNEL_BIN)
	@zsh scripts/check-kernel-elf.zsh $(KERNEL_ELF) $(KERNEL_BIN) $(KERNEL_IMAGE_BYTES)

check-c-kernel: check-image $(KERNEL_ELF)
	@zsh scripts/check-c-kernel.zsh $(OS_IMAGE) $(KERNEL_ELF) $(C_KERNEL_EXPECTED_PREFIX)

check-exception: check-image $(KERNEL_ELF)
	@zsh scripts/check-exception.zsh $(OS_IMAGE) $(KERNEL_ELF) $(DEBUGCON_EXPECTED)

check-bootloader-graduation: check-boot check-stage2-handoff check-e820-boot-info check-elf-loader check-long-mode check-exception
	@printf '%s\n' 'bootloader graduation audit passed:'
	@printf '%s\n' '  stage 1 → stage 2 execution boundary'
	@printf '%s\n' '  E820 → boot_info → RDI → C'
	@printf '%s\n' '  ELF PT_LOAD → .bss zero-fill → dedicated stack'
	@printf '%s\n' '  long mode + minimal #UD recovery remain intact'

$(LIMINE_DEPS_STAMP): scripts/fetch-limine.zsh | check-limine-tools
	@zsh scripts/fetch-limine.zsh
	@touch $@

$(LIMINE_HEADER) $(LIMINE_BOOT_EFI): $(LIMINE_DEPS_STAMP)
	@test -f $@

$(LIMINE_KERNEL_OBJ): $(LIMINE_KERNEL_SRC) $(LIMINE_KERNEL_HEADERS) $(LIMINE_HEADER)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_PMM_OBJ): $(LIMINE_PMM_SRC) $(LIMINE_KERNEL_HEADERS) $(LIMINE_HEADER)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_HHDM_OBJ): $(LIMINE_HHDM_SRC) $(LIMINE_KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_FAULTS_OBJ): $(LIMINE_FAULTS_SRC) $(LIMINE_KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_FAULTS_ASM_OBJ): $(LIMINE_FAULTS_ASM_SRC)
	@mkdir -p build
	@nasm -f elf64 -g -F dwarf -o $@ $<

$(LIMINE_VMM_OBJ): $(LIMINE_VMM_SRC) $(LIMINE_KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_VMM_MAPPER_OBJ): $(LIMINE_VMM_MAPPER_SRC) $(LIMINE_KERNEL_HEADERS)
	@mkdir -p build
	@x86_64-elf-gcc $(LIMINE_CFLAGS) -I build/limine/include -c -o $@ $<

$(LIMINE_KERNEL_ELF): $(LIMINE_KERNEL_OBJS) $(LIMINE_KERNEL_LINKER)
	@x86_64-elf-ld -nostdlib -static -z max-page-size=0x1000 --gc-sections -T $(LIMINE_KERNEL_LINKER) -o $@ $(LIMINE_KERNEL_OBJS)

$(LIMINE_IMAGE): $(LIMINE_BOOT_EFI) $(LIMINE_KERNEL_ELF) $(LIMINE_CONFIG)
	@dd if=/dev/zero of=$@ bs=1048576 count=64 status=none
	@mformat -i $@ -F ::
	@mmd -i $@ ::/EFI ::/EFI/BOOT ::/boot ::/boot/limine
	@mcopy -i $@ $(LIMINE_BOOT_EFI) ::/EFI/BOOT/BOOTX64.EFI
	@mcopy -i $@ $(LIMINE_CONFIG) ::/boot/limine/limine.conf
	@mcopy -i $@ $(LIMINE_KERNEL_ELF) ::/boot/kernel.elf

limine-deps: $(LIMINE_HEADER) $(LIMINE_BOOT_EFI)

limine-kernel: $(LIMINE_KERNEL_ELF)

limine-image: $(LIMINE_IMAGE)

run-limine: $(LIMINE_IMAGE)
	@printf '%s\n' 'Limine debug console output follows; press Ctrl-C to stop QEMU.'
	@qemu-system-x86_64 \
		-machine q35 \
		-accel tcg \
		-m 256M \
		-display none \
		-serial none \
		-monitor none \
		-no-reboot \
		-no-shutdown \
		-drive if=pflash,unit=0,format=raw,readonly=on,file=$(OVMF_CODE) \
		-device qemu-xhci \
		-drive if=none,id=bootdisk,format=raw,readonly=on,file=$(LIMINE_IMAGE) \
		-device usb-storage,drive=bootdisk,removable=true \
		-boot order=d \
		-chardev stdio,id=debugcon,signal=off \
		-device isa-debugcon,iobase=0xe9,chardev=debugcon

inspect-limine-api: $(LIMINE_HEADER)
	@printf '%s\n' '== base revision support check =='
	@rg -n -A 2 '^#define LIMINE_BASE_REVISION_SUPPORTED' $(LIMINE_HEADER)
	@printf '%s\n' '== memory-map constants and request/response pointer chain =='
	@rg -n -A 28 '^#define LIMINE_MEMMAP_USABLE' $(LIMINE_HEADER)

inspect-limine-handoff: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== Limine higher-half ELF header and program headers =='
	@x86_64-elf-readelf -h -lW $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== retained request section and protocol objects =='
	@x86_64-elf-readelf -SW $(LIMINE_KERNEL_ELF) | rg 'limine_requests|text|rodata|data|bss'
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'limine_(requests|base_revision|kernel_main)|memory_map_request'

inspect-physical-pages: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== physical-page allocator state and API =='
	@sed -n '1,220p' kernel/pmm.h
	@printf '%s\n' '== lesson implementation slots =='
	@sed -n '1,260p' kernel/pmm.c
	@printf '%s\n' '== linked PMM symbols =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'pmm_(init|alloc_page)'

inspect-hhdm-page: $(LIMINE_KERNEL_ELF) $(LIMINE_HEADER)
	@printf '%s\n' '== pinned Limine HHDM request/response ABI =='
	@rg -n -A 16 '^/\* HHDM \*/' $(LIMINE_HEADER)
	@printf '%s\n' '== lesson 27 HHDM page API and implementation slot =='
	@sed -n '1,180p' kernel/hhdm.h
	@sed -n '1,240p' kernel/hhdm.c
	@printf '%s\n' '== linked HHDM symbols and retained request =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'hhdm_(request|prepare_page)'

inspect-page-fault: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 28 page-fault evidence decoder =='
	@sed -n '1,240p' kernel/faults.h
	@sed -n '1,240p' kernel/faults.c
	@printf '%s\n' '== provided IDT/#PF assembly bridge =='
	@sed -n '1,240p' kernel/faults_asm.asm
	@printf '%s\n' '== linked page-fault symbols =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'page_fault_(entry|handler|decode)|faults_idt_load|kernel_idt'

inspect-kernel-page-table: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 29 inactive kernel page-table path =='
	@sed -n '1,240p' kernel/vmm.h
	@sed -n '1,240p' kernel/vmm.c
	@printf '%s\n' '== linked VMM symbols =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'vmm_map_single_4k'

inspect-kernel-address-space: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 30 root-clone API and CR3 bridge =='
	@sed -n '1,280p' kernel/vmm.h
	@sed -n '1,300p' kernel/vmm.c
	@rg -n -A 8 'static void write_cr3|static uint64_t read_rsp' kernel/limine_main.c
	@printf '%s\n' '== linked address-space symbols =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'vmm_(map_single_4k|clone_root_preserving_entry)'

inspect-demand-page: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 31 demand-write policy and recovery bridge =='
	@rg -n -A 42 'bool vmm_resolve_demand_write' kernel/vmm.c
	@rg -n -A 30 '^page_fault_entry:' kernel/faults_asm.asm
	@printf '%s\n' '== linked recovery symbols and INVLPG instruction =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'vmm_resolve_demand_write|page_fault_(entry|handler)'
	@x86_64-elf-objdump -d -Mintel $(LIMINE_KERNEL_ELF) | rg 'invlpg|iretq'

inspect-page-table-walk: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 32 reusable 4 KiB page-table walker =='
	@rg -n -A 45 'bool vmm_walk_to_pte' kernel/vmm.c
	@printf '%s\n' '== runtime producer and observer =='
	@rg -n -A 48 'uint64_t \*walked_target_pte' kernel/limine_main.c
	@printf '%s\n' '== linked walker symbol =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'vmm_walk_to_pte'

inspect-vmm-mapper: $(LIMINE_KERNEL_ELF)
	@printf '%s\n' '== lesson 33 create/reuse/unmap lifecycle =='
	@sed -n '1,220p' kernel/vmm_mapper.h
	@sed -n '1,300p' kernel/vmm_mapper.c
	@printf '%s\n' '== runtime ownership and alias observer =='
	@rg -n -A 240 'struct vmm_map_result mapper_result' kernel/limine_main.c
	@printf '%s\n' '== linked mapper symbol =='
	@x86_64-elf-nm -n $(LIMINE_KERNEL_ELF) | rg 'vmm_(map|unmap)_page_4k'

check-limine-handoff: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-limine-handoff.zsh $(LIMINE_IMAGE) $(LIMINE_KERNEL_ELF) $(OVMF_CODE)

check-physical-pages: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-physical-pages.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-hhdm-page: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-hhdm-page.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-page-fault: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-page-fault.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-kernel-page-table: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-kernel-page-table.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-kernel-address-space: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-kernel-address-space.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-demand-page: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-demand-page.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-page-table-walk: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-page-table-walk.zsh $(LIMINE_IMAGE) $(OVMF_CODE)

check-vmm-mapper: $(LIMINE_IMAGE)
	@test -f $(OVMF_CODE)
	@zsh scripts/check-vmm-mapper.zsh $(LIMINE_IMAGE) $(OVMF_CODE)
