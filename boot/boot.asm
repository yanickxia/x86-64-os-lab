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

; Keep the GDB checkpoint at the fixed address 0x7c14.
times 0x10 - ($ - $$) db 0x90

stack_probe:
    mov ax, 0x1234
    push ax

after_push:
    mov al, 'X'
    out 0xe9, al

hang:
    jmp hang

times 510 - ($ - $$) db 0
dw 0xaa55
