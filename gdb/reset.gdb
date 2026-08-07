set pagination off
set confirm off
set disassembly-flavor intel

target remote 127.0.0.1:1234

printf "\n--- reset registers ---\n"
info registers rip cs cr0 eflags

printf "\n--- bytes at the reset vector ---\n"
x/16xb 0xfffffff0
dump binary memory build/reset-vector.bin 0xfffffff0 0x100000000

printf "\n--- 16-bit decode of the reset vector ---\n"
shell ndisasm -b 16 -o 0xfffffff0 build/reset-vector.bin

detach
quit
