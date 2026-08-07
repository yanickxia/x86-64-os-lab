set pagination off
set confirm off
set disassembly-flavor intel

hbreak *0x7c10
continue

printf "\n--- segment and stack state at main ---\n"
info registers cs ds es ss sp eflags

set $failed = 0
set $ds_value = (unsigned int)$ds
set $es_value = (unsigned int)$es
set $ss_value = (unsigned int)$ss
set $sp_value = (unsigned int)$sp

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

if (($sp_value & 0xffff) != 0x7c00)
    printf "FAIL: SP expected 0x7c00 at main\n"
    set $failed = 1
end

if ($failed)
    detach
    quit 1
end

printf "segment/stack check passed: DS=ES=SS=0, SP=0x7c00 at main\n"
detach
quit 0
