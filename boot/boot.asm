bits 16
org 0x7c00


start:
    ; Keep the CPU at a stable address so GDB can inspect this sector.
    jmp $

; TODO: Pad the flat binary so the boot signature starts at byte offset 510.
; Hint: NASM's `$` is the current position and `$$` is the section start.

times 510 - ($ - $$) db 0

; TODO: Store the 16-bit boot signature 0xaa55.
; Remember that x86 stores a word in little-endian byte order.

dw 0xaa55