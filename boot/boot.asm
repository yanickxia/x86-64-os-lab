bits 16
org 0x7c00

; These are physical RAM addresses chosen by our bootloader. EQU defines
; constants only; setup_page_tables initializes the memory at runtime.
PML4_ADDR equ 0x00001000
PDPT_ADDR equ 0x00002000
PD_ADDR equ 0x00003000
PAGE_TABLE_DWORDS equ (3 * 4096) / 4


start:
    cli
    xor ax, ax
    mov es, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7c00
    sti

; Keep main at a fixed address for the lesson tests.
times 0x10 - ($ - $$) db 0x90

main:
    ; Enable A20 while keeping fast reset disabled.
    in al, 0x92
    and al, 0xfe
    or al, 0x02
    out 0x92, al

    ; 记录 LGDT 指令
    lgdt [gdt_descriptor]

    mov si, message

.loop:
    mov al, [si]
    test al, al
    jz hang
    call putc
    inc si
    jmp .loop

hang:
    jmp enter_protected_mode

; Keep putc and message at fixed addresses for the lesson tests.
times 0x30 - ($ - $$) db 0x90

putc:
    out 0xe9, al
    ret

times 0x40 - ($ - $$) db 0

message:
    db 'Hello', 0, 'Z'

times 0x50 - ($ - $$) db 0

gdt:
    dq 0x0000000000000000
    dq 0x00cf9a000000ffff
    dq 0x00cf92000000ffff
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt - 1
    dd gdt

times 0x70 - ($ - $$) db 0

bits 16
enter_protected_mode:
    cli
    mov eax, cr0
    or eax, 1
    mov cr0, eax ; 设置 CR0.PE 为 1
    jmp 0x0008:protected_mode_entry ; 进入保护模式
.real_mode_hang:
    jmp .real_mode_hang

times 0x90 - ($ - $$) db 0

bits 32
protected_mode_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x00090000

    mov al, 'P'
    out 0xe9, al

    call setup_page_tables

    mov al, 'T'
    out 0xe9, al

.protected_mode_hang:
    jmp .protected_mode_hang

times 0xb0 - ($ - $$) db 0x90

setup_page_tables:
    ; Clear three 4 KiB pages: PML4, PDPT, and PD.
    cld
    xor eax, eax
    mov edi, PML4_ADDR
    mov ecx, PAGE_TABLE_DWORDS
    rep stosd

    ; Link the root to its next levels, then terminate at a 2 MiB leaf.
    mov dword [PML4_ADDR], PDPT_ADDR | 0x001 | 0x002
    mov dword [PDPT_ADDR], PD_ADDR | 0x001 | 0x002
    mov dword [PD_ADDR], 0 | 0x001 | 0x002 | 0x080
    ret

times 510 - ($ - $$) db 0
dw 0xaa55
