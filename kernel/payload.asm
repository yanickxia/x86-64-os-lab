bits 64
org 0x00010000

kernel_start:
    jmp short kernel_entry

kernel_magic:
    db 'KERNEL64'

kernel_entry:
    mov al, 'K'
    out 0xe9, al
.hang:
    jmp .hang

times 512 - ($ - $$) db 0
