set pagination off
set confirm off
set disassembly-flavor intel

hbreak *0x7c14
continue

printf "\n--- state immediately after push ax ---\n"
info registers cs ds es ss sp ax eflags

set $ds_value = (unsigned int)$ds
set $es_value = (unsigned int)$es
set $ss_value = (unsigned int)$ss
set $sp_value = (unsigned int)$sp
set $stack_linear = (($ss_value & 0xffff) << 4) + ($sp_value & 0xffff)
printf "stack linear address: 0x%lx\n", $stack_linear
x/1hx $stack_linear

set $failed = 0

if (($ds_value & 0xffff) != 0)
    printf "FAIL: DS expected 0x0000\n"
    set $failed = 1
end

if (($es_value & 0xffff) != 0)
    printf "FAIL: ES expected 0x0000\n"
    set $failed = 1
end

if (($ss_value & 0xffff) != 0)
    printf "FAIL: SS expected 0x0000\n"
    set $failed = 1
end

if (($sp_value & 0xffff) != 0x7bfe)
    printf "FAIL: SP expected 0x7bfe after a 16-bit push\n"
    set $failed = 1
end

if (*(unsigned short *)$stack_linear != 0x1234)
    printf "FAIL: word at SS:SP expected 0x1234\n"
    set $failed = 1
end

if ($failed)
    detach
    quit 1
end

printf "segment/stack check passed: DS=ES=SS=0, SP=0x7bfe, [SS:SP]=0x1234\n"
detach
quit 0
