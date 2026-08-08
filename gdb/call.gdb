set pagination off
set confirm off
set disassembly-flavor intel

hbreak *0x7c30
hbreak *0x7c1c
continue

set $pc_value = (unsigned long)$rip

if (($pc_value & 0xffff) != 0x7c30)
    printf "FAIL: expected to stop at putc (0x7c30)\n"
    detach
    quit 1
end

printf "\n--- putc entry: return address is on the stack ---\n"
info registers cs rip ss sp ax

set $ss_value = (unsigned int)$ss
set $sp_value = (unsigned int)$sp
set $stack_linear = (($ss_value & 0xffff) << 4) + ($sp_value & 0xffff)
printf "stack linear address: 0x%lx\n", $stack_linear
x/1hx $stack_linear

if (($sp_value & 0xffff) != 0x7bfe)
    printf "FAIL: SP expected 0x7bfe at putc entry\n"
    detach
    quit 1
end

if (*(unsigned short *)$stack_linear != 0x7c1c)
    printf "FAIL: stack top expected return address 0x7c1c\n"
    detach
    quit 1
end

continue

set $pc_value = (unsigned long)$rip
set $sp_value = (unsigned int)$sp

printf "\n--- after ret: execution resumes after call ---\n"
info registers cs rip ss sp ax

if (($pc_value & 0xffff) != 0x7c1c)
    printf "FAIL: RET did not return to 0x7c1c\n"
    detach
    quit 1
end

if (($sp_value & 0xffff) != 0x7c00)
    printf "FAIL: SP expected 0x7c00 after RET\n"
    detach
    quit 1
end

printf "call/ret check passed: return=0x7c1c, SP 0x7c00 -> 0x7bfe -> 0x7c00\n"
detach
quit 0
