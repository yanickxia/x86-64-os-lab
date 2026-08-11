bits 16
org 0x8000

%ifndef STAGE2_IMAGE_BYTES
%define STAGE2_IMAGE_BYTES 1024
%endif

STAGE2_HANDSHAKE_ADDR equ 0x7000
BOOT_INFO_ADDR equ 0x5000
BOOT_INFO_MAGIC equ 0x464e4942       ; bytes "BINF"
BOOT_INFO_VERSION equ 1
BOOT_INFO_ENTRY_SIZE equ 24
BOOT_INFO_CAPACITY equ 32
BOOT_INFO_ENTRIES_ADDR equ 0x5020
BOOT_INFO_ENTRY_COUNT equ BOOT_INFO_ADDR + 8
E820_FUNCTION equ 0xe820
E820_SIGNATURE equ 0x534d4150        ; "SMAP"
KERNEL_ELF_SCRATCH_SEGMENT equ 0x2000
KERNEL_ELF_IMAGE_BYTES equ 8192
KERNEL_ELF_SECTORS equ 16
KERNEL_ELF_CHS_SECTOR equ 1
KERNEL_ELF_CHS_HEAD equ 1
ELF_PT_LOAD equ 1
ELF64_PROGRAM_HEADER_SIZE equ 56

stage2_start:
    jmp short stage2_entry

stage2_magic:
    db 'STAGE2'

stage2_entry:
    mov [boot_drive], dl

    ; This write is execution evidence. Merely loading stage2.bin at 0x8000
    ; cannot create the independent handshake at physical 0x7000.
    mov dword [STAGE2_HANDSHAKE_ADDR], 0x47415453 ; bytes "STAG"
    mov dword [STAGE2_HANDSHAKE_ADDR + 4], 0x4b4f3245 ; bytes "E2OK"

    push ax
    push bx
    push cx
    push dx
    push di
    push bp
    push ds
    push es

    xor ax, ax
    mov ds, ax
    mov es, ax

    ; Stable 32-byte handoff header shared with kernel/boot_info.h.
    mov dword [BOOT_INFO_ADDR + 0], BOOT_INFO_MAGIC
    mov word [BOOT_INFO_ADDR + 4], BOOT_INFO_VERSION
    mov word [BOOT_INFO_ADDR + 6], BOOT_INFO_ENTRY_SIZE
    mov dword [BOOT_INFO_ADDR + 8], 0
    mov dword [BOOT_INFO_ADDR + 12], BOOT_INFO_CAPACITY
    mov dword [BOOT_INFO_ADDR + 16], BOOT_INFO_ENTRIES_ADDR
    mov dword [BOOT_INFO_ADDR + 20], 0
    mov dword [BOOT_INFO_ADDR + 24], 0
    mov dword [BOOT_INFO_ADDR + 28], 0

    ; Make the C acknowledgement deterministic before entering the kernel.
    mov dword [0x7010], 0
    mov dword [0x7014], 0
    mov dword [0x7018], 0
    mov dword [0x701c], 0

    xor ebx, ebx                    ; continuation token: zero starts E820
    xor bp, bp                      ; internal count, not yet published
    mov di, BOOT_INFO_ENTRIES_ADDR

.e820_next:
    cmp bp, BOOT_INFO_CAPACITY
    jae .e820_done

    mov eax, E820_FUNCTION
    mov edx, E820_SIGNATURE
    mov ecx, BOOT_INFO_ENTRY_SIZE
    mov dword [es:di + 20], 1       ; request/retain extended attributes
    int 0x15
    jc .e820_done
    cmp eax, E820_SIGNATURE
    jne .e820_done
    cmp ecx, 20
    jb .e820_done

    mov eax, [es:di + 8]           ; ignore zero-length ranges
    or eax, [es:di + 12]
    jz .e820_continue

    inc bp
    add di, BOOT_INFO_ENTRY_SIZE

.e820_continue:
    test ebx, ebx
    jnz .e820_next

.e820_done:
    ; RED / TODO (lesson 22): publish BP into boot_info.entry_count.
    mov word [BOOT_INFO_ENTRY_COUNT], bp

    call load_kernel_elf
    jc .elf_failed

    pop es
    pop ds
    pop bp
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

.elf_failed:
    mov al, 'E'
    out 0xe9, al
    jmp .elf_failed

; Read a compact ELF image at CHS 0/1/1 (LBA 18) into 0x20000, then apply
; each PT_LOAD using p_offset, p_paddr, p_filesz, and p_memsz. This teaching
; loader deliberately accepts only low-memory, 16-byte-aligned segments whose
; source and size fit in one 64 KiB real-mode window.
load_kernel_elf:
    mov ax, KERNEL_ELF_SCRATCH_SEGMENT
    mov es, ax
    xor bx, bx

    mov ah, 0x02
    mov al, KERNEL_ELF_SECTORS
    mov ch, 0x00
    mov cl, KERNEL_ELF_CHS_SECTOR
    mov dh, KERNEL_ELF_CHS_HEAD
    mov dl, [boot_drive]
    int 0x13
    jc .bad

    mov ax, KERNEL_ELF_SCRATCH_SEGMENT
    mov ds, ax

    cmp dword [0x00], 0x464c457f    ; ELF magic
    jne .bad_with_scratch_ds
    cmp byte [0x04], 2              ; ELFCLASS64
    jne .bad_with_scratch_ds
    cmp byte [0x05], 1              ; little endian
    jne .bad_with_scratch_ds
    cmp word [0x12], 0x003e         ; EM_X86_64
    jne .bad_with_scratch_ds
    cmp dword [0x1c], 0             ; high half of e_entry
    jne .bad_with_scratch_ds
    cmp dword [0x24], 0             ; high half of e_phoff
    jne .bad_with_scratch_ds
    cmp word [0x36], ELF64_PROGRAM_HEADER_SIZE
    jne .bad_with_scratch_ds

    ; Publish the ELF entry for the later 64-bit handoff. The temporary DS
    ; switch is necessary because boot_info lives in segment zero.
    mov eax, [0x18]
    push ds
    xor dx, dx
    mov ds, dx
    mov [BOOT_INFO_ADDR + 24], eax
    mov dword [BOOT_INFO_ADDR + 28], 0
    pop ds

    mov si, [0x20]                  ; e_phoff
    mov bx, [0x38]                  ; e_phnum

.next_program_header:
    test bx, bx
    jz .loaded
    cmp dword [si + 0], ELF_PT_LOAD
    jne .advance_program_header

    push bx
    mov bp, si

    ; Reject values this intentionally small real-mode loader cannot express.
    ; BP-based addresses default to SS on x86, so each program-header read
    ; needs an explicit DS override to address the ELF scratch segment.
    cmp dword [ds:bp + 12], 0       ; p_offset high half
    jne .bad_load
    cmp dword [ds:bp + 28], 0       ; p_paddr high half
    jne .bad_load
    cmp dword [ds:bp + 36], 0       ; p_filesz high half
    jne .bad_load
    cmp dword [ds:bp + 44], 0       ; p_memsz high half
    jne .bad_load
    cmp dword [ds:bp + 32], 0xffff
    ja .bad_load
    cmp dword [ds:bp + 40], 0xffff
    ja .bad_load
    mov eax, [ds:bp + 40]
    cmp eax, [ds:bp + 32]
    jb .bad_load
    mov eax, [ds:bp + 8]
    add eax, [ds:bp + 32]
    cmp eax, KERNEL_ELF_IMAGE_BYTES
    ja .bad_load
    mov eax, [ds:bp + 24]
    test al, 0x0f
    jnz .bad_load
    cmp eax, 0x000ffff0
    ja .bad_load

    ; DS:SI points into the file image; ES:DI points at p_paddr.
    shr eax, 4
    mov es, ax
    xor di, di
    mov si, [ds:bp + 8]
    mov cx, [ds:bp + 32]
    cld
    rep movsb                       ; copy p_filesz bytes

    ; Turn the normally-zero QEMU RAM into stable red-light evidence first.
    ; The missing line must then establish the ELF rule:
    ; p_memsz - p_filesz bytes become zero.
    mov cx, [ds:bp + 40]
    sub cx, [ds:bp + 32]
    mov dx, cx
    mov al, 0xa5
    rep stosb
    sub di, dx
    mov cx, dx
    xor al, al
    ; RED / TODO (lesson 23): zero the NOBITS tail with one string instruction.
    rep stosb

    mov si, bp
    pop bx

.advance_program_header:
    add si, ELF64_PROGRAM_HEADER_SIZE
    dec bx
    jmp .next_program_header

.bad_load:
    pop bx

.bad_with_scratch_ds:
    xor ax, ax
    mov ds, ax
.bad:
    stc
    ret

.loaded:
    xor ax, ax
    mov ds, ax
    clc
    ret

boot_drive:
    db 0

times STAGE2_IMAGE_BYTES - 8 - ($ - $$) db 0
db 'S2TAIL!!'
