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

stage2_start:
    jmp short stage2_entry

stage2_magic:
    db 'STAGE2'

stage2_entry:
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

    pop es
    pop ds
    pop bp
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
    ret

times STAGE2_IMAGE_BYTES - 8 - ($ - $$) db 0
db 'S2TAIL!!'
