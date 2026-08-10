bits 64

section .text
global kernel_start
global kernel_magic
global kernel_entry
global kernel_hang

kernel_start:
    jmp short kernel_entry

kernel_magic:
    db 'KERNEL64'

kernel_entry:
    mov al, 'K'
    out 0xe9, al
kernel_hang:
    jmp kernel_hang

times 512 - ($ - $$) db 0
