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
    mov al, 'X'
    call putc

hang:
    jmp hang

; Keep putc at 0x7c20 so its entry state is predictable in GDB.
times 0x20 - ($ - $$) db 0x90

putc:
    out 0xe9, al
    ret

times 510 - ($ - $$) db 0
dw 0xaa55
