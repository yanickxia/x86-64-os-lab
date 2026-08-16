bits 64

section .text
global faults_idt_load
global page_fault_entry

extern page_fault_handler

; SysV: RDI points at a packed 10-byte IDTR pseudo-descriptor.
faults_idt_load:
    lidt [rdi]
    ret

; For a same-privilege #PF, the CPU pushes error code, RIP, CS and RFLAGS.
; RSP/SS are added only when the exception crosses privilege levels. Preserve
; all GPRs before entering C. A recoverable handler returns here; IRETQ then
; retries the saved RIP after the handler has repaired the mapping.
page_fault_entry:
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

    mov rdi, [rsp + 15 * 8]
    lea rsi, [rsp + 16 * 8]
    sub rsp, 8
    call page_fault_handler
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

    add rsp, 8
    iretq
