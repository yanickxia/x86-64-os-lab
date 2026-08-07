set pagination off
set confirm off
set disassembly-flavor intel

target remote 127.0.0.1:1234
hbreak *0x7c00
continue

printf "\n--- BIOS handoff registers ---\n"
info registers rip cs ds ss sp cr0

printf "\n--- bytes loaded by BIOS at 0x7c00 ---\n"
x/16xb 0x7c00
dump binary memory build/loaded-boot.bin 0x7c00 0x7e00

printf "\n--- compare disk sector with guest memory ---\n"
shell cmp build/boot.bin build/loaded-boot.bin && printf "identical: build/boot.bin == memory[0x7c00..0x7dff]\n"

printf "\n--- 16-bit decode at 0x7c00 ---\n"
shell ndisasm -b 16 -o 0x7c00 build/loaded-boot.bin | head -n 8

detach
quit

