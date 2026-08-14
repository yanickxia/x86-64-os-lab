bits 64

section .text
global faults_idt_load
global page_fault_entry

extern page_fault_handler

; SysV: RDI points at a packed 10-byte IDTR pseudo-descriptor.
faults_idt_load:
    lidt [rdi]
    ret

; #PF pushes an error code before RIP, CS, RFLAGS, RSP, SS. Preserve all GPRs
; before entering C. The handler is diagnostic and never returns, so this
; lesson deliberately needs no IRETQ recovery path.
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

.unexpected_return:
    cli
    hlt
    jmp .unexpected_return
