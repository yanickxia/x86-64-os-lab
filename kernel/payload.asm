bits 64

section .text.entry
global kernel_start
global kernel_magic
global kernel_entry
global kernel_hang
global debug_putc
global lesson_idt
global load_lesson_idt
global trigger_invalid_opcode
global isr_invalid_opcode
global exception_red_hang
extern kernel_main
extern invalid_opcode_handler

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

; Load the 7-entry teaching IDT prepared by idt_install(). It is intentionally
; only large enough to include vector 6 (#UD) in this lesson.
load_lesson_idt:
    lidt [rel lesson_idtr]
    ret

; UD2 is exactly two bytes. #UD saves a RIP that still points at UD2.
trigger_invalid_opcode:
    ud2
    ret

; #UD has no error code. In 64-bit mode the CPU frame is RIP, CS, RFLAGS,
; old RSP, old SS even without a CPL change. Save all GPRs before crossing
; into C, then IRETQ through the possibly edited frame.
isr_invalid_opcode:
    cld
    push rax
    push rbx
    push rcx
    push rdx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    lea rdi, [rsp + 15 * 8]
    sub rsp, 8
    call invalid_opcode_handler
    add rsp, 8

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rdx
    pop rcx
    pop rbx
    pop rax
    iretq

exception_red_hang:
    jmp exception_red_hang

section .data
align 16

; Six empty gates followed by vector 6. C fills the final gate at runtime.
lesson_idt:
    times 7 dq 0, 0
lesson_idt_end:

lesson_idtr:
    dw lesson_idt_end - lesson_idt - 1
    dq lesson_idt
