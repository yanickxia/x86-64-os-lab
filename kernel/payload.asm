bits 64

section .text.entry
global kernel_start
global kernel_magic
global kernel_entry
global kernel_hang
global debug_putc
extern kernel_main

kernel_start:
    jmp short kernel_entry

kernel_magic:
    db 'KERNEL64'

kernel_entry:
    ; Bypass the fixed-address hang loop on first entry. Keeping kernel_hang at
    ; 0x1000e preserves the lesson-13/14 machine-state contract.
    jmp short kernel_call_stub
    nop
    nop

kernel_hang:
    jmp kernel_hang

kernel_call_stub:
    mov al, 'K'
    out 0xe9, al
    call kernel_main
    jmp kernel_hang

; SysV x86-64 passes the first integer argument in RDI. OUT consumes AL.
debug_putc:
    mov eax, edi
    out 0xe9, al
    ret
