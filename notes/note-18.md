# 第 18 课学习记录

日期：2026.08.11

## 实验前预测

先不运行 `make check-c-kernel`，根据讲义给出的源码、地址和 ABI 规则作答。预测错误时不要覆盖原答案，在“我的解释”中修正。

### 1. 空函数的输出与最终控制流

我的预测：kernel_main 没有任何输出，RIP 会指向 `kernel_hang`。

### 2. 三个时刻的栈

- `CALL kernel_main` 前的 `RSP`： 0x90000
- 刚进入 `kernel_main` 时的 `RSP`：0x8fff8
- 此时栈顶 8 字节的返回地址：0x10019
- `kernel_main` 返回后的 `RSP`：0x10019

### 3. 加入一行 C 调用后的变化

我的预测：kernel_main 会调用 debug_putc 函数，传递参数 'C'，打印 C

### 4. 字符参数的传递路径

我的预测：应该将 C move 到 edi 里面，然后在 puts 里面 mov eax, edi

## 红灯

`make check-c-kernel` 的原始关键输出：

```text
C-kernel check: kernel_main did not produce the expected observable behavior
C-kernel check: expected 'HelloPTLKC', got 'HelloPTLK'
C-kernel check: implement the single TODO in kernel/main.c
```

为什么这个红灯只指向本课缺失的行为：汇编入口已经输出 `K` 并调用了 `kernel_main`，但空函数立即返回，没有调用已经提供的 `debug_putc`，所以完整输出只缺本课要求的 `C`。

## 我的实现

`kernel/main.c` 中新增的一行：

```c
debug_putc('C');
```

## 绿灯原始观察

### `make inspect-kernel-c`

只粘贴 `kernel_call_stub`、`kernel_main` 和 `debug_putc` 中与控制流有关的几行：

```text

0000000000010010 <kernel_call_stub>:
   10010:       b0 4b                   mov    $0x4b,%al
   10012:       e6 e9                   out    %al,$0xe9
   10014:       e8 07 00 00 00          call   10020 <kernel_main>
   10019:       eb f3                   jmp    1000e <kernel_hang>
== kernel_main C source and target instructions ==

void kernel_main(void) {
    debug_putc('C');
   10020:       bf 43 00 00 00          mov    $0x43,%edi
   10025:       e9 f1 ff ff ff          jmp    1001b <debug_putc>


000000000001001b <debug_putc>:
   1001b:       89 f8                   mov    %edi,%eax
   1001d:       e6 e9                   out    %al,$0xe9
   1001f:       c3                      ret

```


### 三项检查

```text
# make check-c-kernel

C-kernel check passed: assembly called kernel_main and received 'HelloPTLKC'

# make check-kernel-entry

kernel-entry check passed: payload output begins 'HelloPTLK' and RIP=0x1000e under CS=0x18 (CS64)

# make check-page-tables
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
page-table synchronization output: received 'HelloPTLKC' from I/O port 0xe9
page-table check passed: low 2 MiB identity map is present (CPU Accessed/Dirty bits may be set)
page-table state: PML4[0]=00001000: 0x0000000000002023
page-table state: PDPT[0]=00002000: 0x0000000000003023
page-table state: PD[0]  =00003000: 0x00000000000000e3
```

## 我的解释

### 0. 实验前预测复盘

- 空的 `kernel_main` 自身没有输出；但此前启动路径和汇编入口已经输出 `HelloPTLK`。它返回后，最终 `RIP=0x1000e`，停在 `kernel_hang`。
- `CALL kernel_main` 前 `RSP=0x90000`；`CALL` 压入 8 字节返回地址 `0x10019` 后，callee 入口看到 `RSP=0x8fff8`；最终 `RET` 弹出返回地址，`RSP` 恢复为 `0x90000`。实验前把指令地址 `0x10019` 误当成了返回后的栈指针。
- 加入 `debug_putc('C')` 后，完整输出从 `HelloPTLK` 变成 `HelloPTLKC`；最终 `RIP` 仍为 `0x1000e`。
- 字符 `C` 的数值是 `0x43`。C 代码按 ABI 把它放入 `EDI`，`debug_putc` 再执行 `mov eax, edi`，所以 `AL=0x43`，最后由 `out 0xe9, al` 输出。

### 1. 汇编调用点、返回地址与编译器实现

汇编在 `0x10014` 执行 `call 0x10020 <kernel_main>`，因此压栈的返回地址是下一条指令 `0x10019`。编译器把位于函数末尾的 `debug_putc('C')` 优化成 tail call：

```text
0x10020  mov $0x43, %edi
0x10025  jmp 0x1001b <debug_putc>
```

这里没有第二次 `CALL`，也不会再压入一层返回地址。`debug_putc` 完成输出后执行 `RET`，直接弹出最初由汇编入口保存的 `0x10019`，然后汇编跳到 `kernel_hang`。若编译器生成普通的 `call debug_putc; ret`，C 语义也相同；tail call 只是减少了一层调用和返回。

### 2. target toolchain 与 freestanding

- toolchain 是 x86_64-elf-gcc
- freestanding 环境：不假设存在 printf、文件、进程或宿主 C 库
- 不能直接按普通 macOS 程序构建：当前 host 是 Apple Silicon，宿主编译器默认生成的目标格式、ABI 与运行时依赖都不是裸机 `x86_64-elf`。内核也没有 macOS loader 和 C runtime 为它准备进程入口。

### 3. 输出证据与 RIP 证据

- `HelloPTLKC`：最后的 `C` 证明 `kernel_main` 的 C 路径和汇编 `debug_putc` 都被执行。
- RIP=0x1000e：证明调用正常返回并回到汇编死循环

### 4. 极小 C 函数与完整内核环境的差距

- `.bss` 清零是 C 对未显式初始化的静态/全局变量等于 0 的承诺。当前函数没有这类变量，所以暂时不受影响；以后若页帧计数等状态从 RAM 垃圾值开始，内存管理会出错。
- IDT 告诉 CPU 异常发生后应跳到哪个 handler。当前成功路径不产生异常；以后发生 `#PF/#UD/#DE` 时，无效 IDT 会让递送失败，可能升级为 `#DF` 和 triple fault，外部只看到重启。
- stack guard 是放在栈边界的未映射保护页。当前调用只压入一个 8 字节返回地址；以后深递归或巨大局部变量可能越界并静默覆盖内核数据，有 guard 后跨界会触发可诊断的 `#PF`。

因此输出一个字符只证明这条极小路径实际使用的合同成立，不能证明尚未触发的 `.bss`、异常处理和栈边界合同已经建立。

## OS 视角

用 2–4 句话回答：为什么从现在开始，大多数内核机制适合写在 C 中，而异常入口、上下文切换和系统调用入口仍会保留少量汇编？

大多数内核策略和数据结构适合用 C 表达，因为类型、控制结构和模块边界更容易阅读、测试与维护。异常入口、上下文切换和系统调用入口仍保留少量汇编，不是主要为了性能，而是因为 CPU 对进入和离开这些边界时的寄存器、栈布局及特殊返回指令有精确规定；汇编先把机器状态整理成 C 能依赖的合同，再把主体逻辑交给 C。


## 仍然不清楚的问题

-
