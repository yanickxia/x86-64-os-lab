# 第 22 课学习记录

日期：2026.08.11

> 填写时机：先读完讲义第 1–5 节，理解 E820 loop、boot_info layout、ABI handoff 和红灯机制；然后在第一次运行 `make check-e820-boot-info` 前填写预测。

## 实验前预测

### 1. 红灯 header qword

- monitor `xp /1gx 0x5000`： 0x00180001464e4942
- monitor `xp /1gx 0x5008`：0x0000002000000000
- little-endian 推导：0x5008 的低 32 位是 entry_count=0，高 32 位是 capacity=32。

### 2. 合成 E820 循环

初始：BP=0, DI=0x5020
call 1：BP=1, DI=0x5038
call 2：BP=1, DI=0x5038
call 3：BP=2, DI=0x5050

最终 entry_count=2

### 3. 红灯中的 C 行为

entry_count = 0
C 拒绝 boot_info
0x7010 = 0x0000000000000000
debug output = HelloPTLKCUR


### 4. 绿灯 acknowledgement

- `0x7010..0x7017` bytes： 45 38 32 30 43 4f 4b 21
- monitor qword：0x214b4f4330323845
- 串起的三个阶段：stage 2 收集并发布 → RDI=0x5000 handoff → C 校验并消费。

### 5. `RDI` 与 header

- `mov edi, 0x5000` 后的 `RDI`： 0x0000000000005000
- 为什么不能只传 entries 地址：需要检查 magic header 是否正确

## 红灯

### `make inspect-boot-info`

```text
$ make inspect-boot-info
== E820 query and boot_info publication in stage 2 ==
20:0000803D  66C7060850000000  mov dword [0x5008],0x0
22:00008046  66C7060C50200000  mov dword [0x500c],0x20
24:0000804F  66C7061050205000  mov dword [0x5010],0x5020
38:0000808A  BF2050            mov di,0x5020
42:00008098  66BA50414D53      mov edx,0x534d4150
48:000080B1  663D50414D53      cmp eax,0x534d4150
67:000080DC  C3                ret
== C boot_info consumer ==
    }
}

void kernel_main(const struct boot_info *boot_info) {
   10070:       55                      push   %rbp
   10071:       48 89 e5                mov    %rsp,%rbp
   10074:       53                      push   %rbx
   10075:       48 89 fb                mov    %rdi,%rbx
    debug_putc('C');
   10078:       bf 43 00 00 00          mov    $0x43,%edi
void kernel_main(const struct boot_info *boot_info) {
   1007d:       48 83 ec 08             sub    $0x8,%rsp
    debug_putc('C');
   10081:       e8 95 ff ff ff          call   1001b <debug_putc>
--
        || info->entry_size != sizeof(struct e820_entry)
   1009a:       66 83 7b 06 18          cmpw   $0x18,0x6(%rbx)
   1009f:       75 57                   jne    100f8 <kernel_main+0x88>
        || info->entry_count == 0
   100a1:       8b 53 08                mov    0x8(%rbx),%edx
   100a4:       85 d2                   test   %edx,%edx
   100a6:       74 50                   je     100f8 <kernel_main+0x88>
        || info->entry_count > info->entry_capacity
   100a8:       8b 43 0c                mov    0xc(%rbx),%eax
        || info->entry_capacity > BOOT_INFO_MAX_ENTRIES
   100ab:       83 f8 20                cmp    $0x20,%eax
--
   100cb:       00
   100cc:       eb 0b                   jmp    100d9 <kernel_main+0x69>
   100ce:       66 90                   xchg   %ax,%ax
    for (uint32_t index = 0; index < info->entry_count; index++) {
   100d0:       48 83 c0 18             add    $0x18,%rax
   100d4:       48 39 d0                cmp    %rdx,%rax
   100d7:       74 1f                   je     100f8 <kernel_main+0x88>
        if (entries[index].type == E820_TYPE_USABLE && entries[index].length != 0) {
   100d9:       83 78 10 01             cmpl   $0x1,0x10(%rax)
   100dd:       75 f1                   jne    100d0 <kernel_main+0x60>
   100df:       48 83 78 08 00          cmpq   $0x0,0x8(%rax)
   100e4:       74 ea                   je     100d0 <kernel_main+0x60>
            *(volatile uint64_t *)(uintptr_t)BOOT_INFO_ACK_ADDR = BOOT_INFO_ACK_VALUE;
   100e6:       48 b8 45 38 32 30 43    movabs $0x214b4f4330323845,%rax
   100ed:       4f 4b 21
   100f0:       48 89 04 25 10 70 00    mov    %rax,0x7010
   100f7:       00
    acknowledge_boot_info(boot_info);
    idt_install();
   100f8:       e8 23 00 00 00          call   10120 <idt_install>
    trigger_invalid_opcode();
```

### `make check-e820-boot-info`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
E820 check: firmware entries exist at 0x5020, but stage 2 published entry_count=0
E820 check: publish the internal BP count at the lesson-22 TODO
E820 check: C acknowledgement remains 0x0000000000000000 at 0x7010
make: *** [check-e820-boot-info] Error 1
```

为什么这证明“entries 已收集，但 metadata 尚未发布”：

- `0x5028` 中第一个 E820 entry 的 length 已经非零，证明 BIOS 确实写入了 range。
- `boot_info.entry_count` 仍为 0，说明 stage 2 的内部统计还没有发布给 consumer。
- `0x7010` 仍为 0，说明 C 按合同拒绝了 count 为 0 的 header，没有伪装成功。

## 我的实现

`boot/stage2.asm` 中新增的一行：

```asm
mov word [BOOT_INFO_ENTRY_COUNT], bp
```

## 绿灯原始观察

### `make inspect-boot-info`

只记录发布 count 的指令与 C consumer 的关键检查：

```text
$ make inspect-boot-info
== E820 query and boot_info publication in stage 2 ==
20:0000803D  66C7060850000000  mov dword [0x5008],0x0
22:00008046  66C7060C50200000  mov dword [0x500c],0x20
24:0000804F  66C7061050205000  mov dword [0x5010],0x5020
38:0000808A  BF2050            mov di,0x5020
42:00008098  66BA50414D53      mov edx,0x534d4150
48:000080B1  663D50414D53      cmp eax,0x534d4150
59:000080D4  892E0850          mov [0x5008],bp
68:000080E0  C3                ret
== C boot_info consumer ==
    }
}

void kernel_main(const struct boot_info *boot_info) {
   10070:       55                      push   %rbp
   10071:       48 89 e5                mov    %rsp,%rbp
   10074:       53                      push   %rbx
   10075:       48 89 fb                mov    %rdi,%rbx
    debug_putc('C');
   10078:       bf 43 00 00 00          mov    $0x43,%edi
void kernel_main(const struct boot_info *boot_info) {
   1007d:       48 83 ec 08             sub    $0x8,%rsp
    debug_putc('C');
   10081:       e8 95 ff ff ff          call   1001b <debug_putc>
--
        || info->entry_size != sizeof(struct e820_entry)
   1009a:       66 83 7b 06 18          cmpw   $0x18,0x6(%rbx)
   1009f:       75 57                   jne    100f8 <kernel_main+0x88>
        || info->entry_count == 0
   100a1:       8b 53 08                mov    0x8(%rbx),%edx
   100a4:       85 d2                   test   %edx,%edx
   100a6:       74 50                   je     100f8 <kernel_main+0x88>
        || info->entry_count > info->entry_capacity
   100a8:       8b 43 0c                mov    0xc(%rbx),%eax
        || info->entry_capacity > BOOT_INFO_MAX_ENTRIES
   100ab:       83 f8 20                cmp    $0x20,%eax
--
   100cb:       00
   100cc:       eb 0b                   jmp    100d9 <kernel_main+0x69>
   100ce:       66 90                   xchg   %ax,%ax
    for (uint32_t index = 0; index < info->entry_count; index++) {
   100d0:       48 83 c0 18             add    $0x18,%rax
   100d4:       48 39 d0                cmp    %rdx,%rax
   100d7:       74 1f                   je     100f8 <kernel_main+0x88>
        if (entries[index].type == E820_TYPE_USABLE && entries[index].length != 0) {
   100d9:       83 78 10 01             cmpl   $0x1,0x10(%rax)
   100dd:       75 f1                   jne    100d0 <kernel_main+0x60>
   100df:       48 83 78 08 00          cmpq   $0x0,0x8(%rax)
   100e4:       74 ea                   je     100d0 <kernel_main+0x60>
            *(volatile uint64_t *)(uintptr_t)BOOT_INFO_ACK_ADDR = BOOT_INFO_ACK_VALUE;
   100e6:       48 b8 45 38 32 30 43    movabs $0x214b4f4330323845,%rax
   100ed:       4f 4b 21
   100f0:       48 89 04 25 10 70 00    mov    %rax,0x7010
   100f7:       00
    acknowledge_boot_info(boot_info);
    idt_install();
   100f8:       e8 23 00 00 00          call   10120 <idt_install>
    trigger_invalid_opcode();
```

### `make check-e820-boot-info`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
E820 check passed: stage 2 published 7/32 entries and C consumed boot_info
E820 state: header=0x00180001464e4942, entries=0x5020, first_length=0x000000000009fc00, C_ack=0x214b4f4330323845, output='HelloPTLKCUR'
```

### 两项旧回归

```text
$ make check-stage2-handoff
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
stage2 check passed: stage 1 loaded and called stage 2, which returned to the historical boot path
stage2 state: image 0x8000..0x83ff, handshake 0x4b4f324547415453 at 0x7000, output='HelloPTLKCUR'

$ make check-exception
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x0000000000010180 limit=0x006f, output='HelloPTLKCUR'
```

## 我的解释

### 1. 为什么 entries 存在仍不能安全遍历

我的解释：buffer 中出现非零 bytes 只证明 BIOS 写过内存，不能说明 pointer、entry size 和有效项数。C 必须先验证 magic/version/size/count/capacity/pointer，再严格按公开的 `entry_count` 遍历；否则可能把未初始化内存或其他对象当成 entries，越过 `0x5020..0x531f` 的边界。

实验后修正（保留上面的原始预测）：

```text
xp /1gx 0x5000 → 0x00180001464e4942
xp /1gx 0x5008 → 0x0000002000000000
```

`0x5008` qword 的低 32 位是 `entry_count=0`，高 32 位是 `entry_capacity=32`。monitor 将低地址中的最低有效字节组成整数后，把最高有效位显示在左侧。

红灯时 C 不写 acknowledgement：`entry_count=0` 会在 header 校验阶段被拒绝，所以 `0x7010=0x0000000000000000`；stage 2 和旧 kernel 路径仍正常，因此 debug output 继续是 `HelloPTLKCUR`。

### 2. continuation、内部 count 与公开 count

我的解释：
- `EBX` continuation token 是 BIOS 返回的不透明续查令牌：第一次传 0，之后原样传回；返回 0 表示处理完当前项后结束。它不是 count，也不能由 stage 2 自己递增。
- 内部 `BP` 是 stage 2 已接纳的非零 length entry 数量，只在采集循环内部使用。
- 公开 `entry_count` 是 stage 2 写入 header、允许 C 遍历的有效项数；未发布时 C 必须视为 0 项。

合成输入的实验后计算：

```text
初始： BP=0, DI=0x5020
call 1 非零：BP=1, DI=0x5038
call 2 为零：BP=1, DI=0x5038
call 3 非零：BP=2, DI=0x5050
```

因此最终内部 `BP=2`、`DI=0x5050`，正确发布的 `entry_count=2`。zero-length entry 不占公开 slot，下一次 BIOS 调用覆盖同一地址。

### 3. size、count 与 capacity

我的解释：
- `entry_size=24`：producer 与 consumer 共同使用的数组步长。
- `entry_count`：producer 实际发布、consumer 可以读取的有效项数。
- `entry_capacity=32`：`0x5020` buffer 最多能容纳的项数，不是当前项数。

C 必须验证 `0 < count <= capacity <= 32`，这样 `entries[index]` 才不会越过预留 buffer；还要验证 `entry_size`，否则双方对下一项地址的计算会不同。

### 4. E820 到 C acknowledgement 的证据链

我的解释：

```text
SeaBIOS E820 把一项 range 写到 ES:DI
→ stage 2 校验 CF/SMAP/size，统计非空 entries
→ stage 2 把 BP 发布为 boot_info.entry_count
→ stage 2 RET，stage 1 完成模式切换
→ long-mode entry 设置 RDI=0x5000
→ kernel_main 校验 boot_info header
→ C 在公开的 count 范围内找到非空 usable entry
→ C 在 0x7010 写 bytes E820COK!
→ host checker 读到 qword 0x214b4f4330323845
```

这份 acknowledgement 是课程测试回执，不属于 E820 标准，也不会返回给已经结束的 BIOS 调用或 stage 2。

### 5. 为什么还不能直接分配这些页面

我的解释：`type=1` 只把 range 标为 usable 候选。本课还没有把区间起点向上、终点向下对齐到 4 KiB 页，也没有扣除 kernel、page tables、boot sector/stage 2、`boot_info` 和其他内核保留范围；更没有维护 free/allocated 状态。因此 acknowledgement 只能证明 handoff 数据通路成功，不能把这些 bytes 直接交给 allocator。

## 仍然不清楚的问题

- 暂无。后续进入物理页分配器时，再把 E820 的 usable ranges 变成经过页对齐、保留区扣除和状态管理的可分配页集合。
