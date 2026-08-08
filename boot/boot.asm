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

times 510 - ($ - $$) db 0
dw 0xaa55
