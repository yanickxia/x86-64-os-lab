# 第 19 课学习记录

日期：2026.08.11

## 实验前预测

先不运行 `make check-exception`。只使用讲义“实验前预测”给出的源码、地址和 CPU 规则作答；错误预测不要覆盖，实验后在“我的解释”中修正。

### 1. 红灯输出与最终位置

我的预测：打印 HelloPTLKC，但是不会打印 R，因为 R 之前触发的异常， handler  = isr_invalid_opcode，固定在 0x1006e

### 2. 保存 RIP 与恢复地址

- `frame->rip`：     0x1006e
- 应恢复到：     这2个问题，感觉不能从文档里面算出来
- 计算依据：    同上

### 3. 绿灯控制流与完整输出

我的预测：#UD -> invalid_opcode_handler -> exception_red_hang

### 4. IDTR.limit 与表的范围

我的预测：应该只是一个最小表，不是 256 的完整 IDT，因为只有 6 个异常向量，其他都是保留的。

## 红灯

`make check-exception` 的原始关键输出：

```text
exception check: #UD reached the C handler but did not resume
exception check: expected 'HelloPTLKCUR', got 'HelloPTLKCU'
exception check: advance the saved RIP past the two-byte UD2 in kernel/interrupts.c
exception check: expected execution to return and park at RIP=0x1000e
exception check: actual RIP=0x000000000001006e
make: *** [check-exception] Error 1
```

为什么这说明异常已经进入 C，但还没有恢复：

输出出现 U，证明 vector 6 已进入 C handler。
没有 R，证明尚未恢复到 UD2 后面。
RIP=0x1006e，证明停在预设红灯循环。

## 我的实现

`kernel/interrupts.c` 中新增的一行：

```c
resume_rip += 2;
```

## 绿灯原始观察

### `make inspect-exception`

只粘贴这些证据：`UD2` 地址、汇编入口的 `call invalid_opcode_handler` 与 `iretq`、C handler 对保存 RIP 的修改。

```text
$ make inspect-exception
== lesson IDT and exception symbols ==
0000000000010020 T load_lesson_idt
0000000000010028 T trigger_invalid_opcode
000000000001002b T isr_invalid_opcode
000000000001006e T exception_red_hang
00000000000100e0 T invalid_opcode_handler
0000000000010100 T lesson_idt
0000000000010170 t lesson_idt_end
0000000000010170 t lesson_idtr
== deliberate invalid-opcode trigger ==

build/kernel.elf:     file format elf64-x86-64


Disassembly of section .text:

0000000000010028 <trigger_invalid_opcode>:
   10028:       0f 0b                   ud2
   1002a:       c3                      ret
== invalid-opcode assembly entry ==

build/kernel.elf:     file format elf64-x86-64


Disassembly of section .text:

000000000001002b <isr_invalid_opcode>:
   1002b:       fc                      cld
   1002c:       50                      push   %rax
   1002d:       53                      push   %rbx
   1002e:       51                      push   %rcx
   1002f:       52                      push   %rdx
   10030:       55                      push   %rbp
   10031:       56                      push   %rsi
   10032:       57                      push   %rdi
   10033:       41 50                   push   %r8
   10035:       41 51                   push   %r9
   10037:       41 52                   push   %r10
   10039:       41 53                   push   %r11
   1003b:       41 54                   push   %r12
   1003d:       41 55                   push   %r13
   1003f:       41 56                   push   %r14
   10041:       41 57                   push   %r15
   10043:       48 8d 7c 24 78          lea    0x78(%rsp),%rdi
   10048:       48 83 ec 08             sub    $0x8,%rsp
   1004c:       e8 8f 00 00 00          call   100e0 <invalid_opcode_handler>
   10051:       48 83 c4 08             add    $0x8,%rsp
   10055:       41 5f                   pop    %r15
   10057:       41 5e                   pop    %r14
   10059:       41 5d                   pop    %r13
   1005b:       41 5c                   pop    %r12
   1005d:       41 5b                   pop    %r11
   1005f:       41 5a                   pop    %r10
   10061:       41 59                   pop    %r9
   10063:       41 58                   pop    %r8
   10065:       5f                      pop    %rdi
   10066:       5e                      pop    %rsi
   10067:       5d                      pop    %rbp
   10068:       5a                      pop    %rdx
   10069:       59                      pop    %rcx
   1006a:       5b                      pop    %rbx
   1006b:       58                      pop    %rax
   1006c:       48 cf                   iretq
== invalid-opcode C policy ==

build/kernel.elf:     file format elf64-x86-64


Disassembly of section .text:

00000000000100e0 <invalid_opcode_handler>:
    };

    load_lesson_idt();
}

void invalid_opcode_handler(struct exception_frame *frame) {
   100e0:       55                      push   %rbp
   100e1:       48 89 e5                mov    %rsp,%rbp
   100e4:       53                      push   %rbx
   100e5:       48 89 fb                mov    %rdi,%rbx
    debug_putc('U');
   100e8:       bf 55 00 00 00          mov    $0x55,%edi
void invalid_opcode_handler(struct exception_frame *frame) {
   100ed:       48 83 ec 08             sub    $0x8,%rsp
    debug_putc('U');
   100f1:       e8 25 ff ff ff          call   1001b <debug_putc>
     * For #UD, fault_rip still points at UD2. Set resume_rip to the address of
     * the following RET; do not edit frame->rip directly here.
     * RED / TODO (lesson 19): advance resume_rip past UD2.
     */

    resume_rip += 2;
   100f6:       48 83 03 02             addq   $0x2,(%rbx)
    /* A stable red-light guard: unchanged means the recovery policy is absent. */
    if (resume_rip == fault_rip) {
        exception_red_hang();
    }
    frame->rip = resume_rip;
}
   100fa:       48 8b 5d f8             mov    -0x8(%rbp),%rbx
   100fe:       c9                      leave
   100ff:       c3                      ret

```

### 三项检查

```text
# make check-exception

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x0000000000010100 limit=0x006f, output='HelloPTLKCUR'

# make check-c-kernel

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
C-kernel check passed: assembly called kernel_main and output begins 'HelloPTLKC'
qemu-system-x86_64: terminating on signal 15 from pid 75037 (<unknown process>)

# make check-kernel-entry

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
kernel-entry check passed: payload output begins 'HelloPTLK', RIP=0x000000000001000e is inside the payload, and CS=0x18 (CS64)
QEMU 11.0.3 monitor - type 'help' for more information
(qemu) info registers
```

## 我的解释

### 1. 完整异常控制流

UD2
→ #UD / vector 6
→ isr_invalid_opcode
→ invalid_opcode_handler 输出 U
→ resume_rip=0x1002a，判断为假，不执行 exception_red_hang
→ 写回 frame->rip
→ IRETQ 到 0x1002a
→ RET 回 kernel_main
→ 输出 R
→ kernel_hang 0x1000e

### 2. exception 为什么不受 `CLI` 屏蔽

因为 exception 不是可屏蔽中断，所以不会被 `CLI` 屏蔽。

### 3. 汇编入口为什么要保存寄存器并对齐栈

C 编译器不知道自己会在这里被异步打断；如果 handler 随意破坏寄存器，恢复后原代码可能在很远的位置才表现出错误。脚手架还负责重新满足 C ABI 的栈对齐

### 4. 为什么不能通用地跳过未知 `#UD`

原因是非法指令长度不固定，而且盲目跳过会掩盖程序损坏。用户态通常终止进程；内核态通常打印现场后 panic。

### 5. 当前 7-entry IDT 的边界

0..6 一共是 7 个 entry。
只有 vector 6 被安装，0..5 是空 gate。
#PF 是 vector 14，超出 limit=0x6f。
递送 #PF 时无法取得 gate，可能继续升级为 #DF 和 triple fault。


## OS 视角

用自己的话说明哪些部分是 x86-64 特有胶水，哪些部分在 xv6/RISC-V 等其他架构上仍有相同角色。

入口胶水 → 统一状态 → C 策略 → 特殊返回

## 仍然不清楚的问题

-
