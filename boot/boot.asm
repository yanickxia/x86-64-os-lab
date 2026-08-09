bits 16
org 0x7c00


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
    jmp hang

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

times 510 - ($ - $$) db 0
dw 0xaa55
