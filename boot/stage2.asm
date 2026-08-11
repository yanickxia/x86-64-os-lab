bits 16
org 0x8000

%ifndef STAGE2_IMAGE_BYTES
%define STAGE2_IMAGE_BYTES 1024
%endif

STAGE2_HANDSHAKE_ADDR equ 0x7000

stage2_start:
    jmp short stage2_entry

stage2_magic:
    db 'STAGE2'

stage2_entry:
    ; This write is execution evidence. Merely loading stage2.bin at 0x8000
    ; cannot create the independent handshake at physical 0x7000.
    mov dword [STAGE2_HANDSHAKE_ADDR], 0x47415453 ; bytes "STAG"
    mov dword [STAGE2_HANDSHAKE_ADDR + 4], 0x4b4f3245 ; bytes "E2OK"
    ret

times STAGE2_IMAGE_BYTES - 8 - ($ - $$) db 0
db 'S2TAIL!!'
