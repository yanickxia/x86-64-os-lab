# 第 18 课：从汇编入口调用第一个 C 函数

## 先修知识

开始前只需要记住四件事：

- 第 13–14 课已经证明：CPU 在 64 位模式下从 `0x10000` 执行载荷，ELF 的链接地址也与真实加载地址一致。
- 当前 `RSP=0x90000`，低 2 MiB 恒等映射包含代码和栈。
- 第 5 课已经见过 `CALL` 把返回地址压栈、`RET` 取回返回地址。
- C 函数不是一种新的 CPU 执行模式。编译器最终仍生成普通机器指令；汇编和 C 只要遵守同一份调用约定，就可以互相调用。

权威参考：

- [System V AMD64 ABI 的 Function Calling Sequence](https://gitlab.com/x86-psABIs/x86-64-ABI/-/blob/master/x86-64-ABI/low-level-sys-info.tex)：参数寄存器、调用者/被调用者保存寄存器和栈对齐规则。
- [GCC `-ffreestanding`](https://gcc.gnu.org/onlinedocs/gcc/C-Dialect-Options.html#index-ffreestanding)：内核属于可能没有标准库、入口也不必是 hosted `main` 的 freestanding 环境。
- [GCC x86 options](https://gcc.gnu.org/onlinedocs/gcc/x86-Options.html#index-mno-red-zone)：`-mno-red-zone` 禁止编译器使用 `RSP` 下方的 red zone。

本课不要求记忆编译器参数、linker script 语法或 C 的机器码。它们是已经验收过的桥接基础设施。

## 本课只引入一个机制

**让 64 位汇编入口按照 System V x86-64 ABI 调用 `kernel_main()`，再由 C 调用一个汇编输出函数。**

```text
bootloader
   │ JMP 0x10000
   ▼
assembly kernel_entry
   │ CALL kernel_main
   ▼
C kernel_main
   │ debug_putc('C')
   ▼
assembly debug_putc → port 0xe9
```

这条边界一旦成立，后续内存管理、异常分派、进程和文件系统的主体就可以用 C 实现。汇编只留在 CPU 必须规定机器状态的边界上。

## 实验输入：稍后预测会用到

下面先给出当前源码和本课需要的 ABI 规则。此处只阅读，**暂时不要作答，也不要运行 `make check-c-kernel`**；读完正文和红灯成因后再填写预测。

### 输入 A：汇编入口

脚手架已经提供：

```asm
kernel_call_stub:                 ; 0x10010
    mov al, 'K'
    out 0xe9, al
    call kernel_main              ; CALL 位于 0x10014，下一条是 0x10019
    jmp kernel_hang

debug_putc:                       ; void debug_putc(char ch)
    mov eax, edi
    out 0xe9, al
    ret
```

进入 `kernel_call_stub` 前，debug console 已经收到 `HelloPTL`，`RSP=0x90000`。`kernel_hang` 是固定在 `0x1000e` 的死循环。

### 输入 B：当前 C 函数

```c
void debug_putc(char ch);

void kernel_main(void) {
    /* RED / TODO: emit 'C' through the provided debug_putc(). */
}
```

当前函数体为空，编译出的有效行为等价于直接 `return`。本课唯一允许的修改是在函数体中调用一次已经声明的 `debug_putc`。

### 输入 C：本课会用到的 ABI 规则

- 第一个整数或指针参数通过 `RDI` 传入；`char` 的有效值位于其低位。
- `CALL` 先把下一条指令地址压入 8 字节栈，再跳到 callee。
- 调用者在执行 `CALL` 前令 `RSP` 是 16 的倍数；压入 8 字节返回地址后，callee 刚进入时 `RSP % 16 == 8`。
- `RET` 弹出 8 字节返回地址。
- `debug_putc` 把 `EDI` 复制到 `EAX`，因此 `AL` 得到字符值，再由 `OUT` 输出。

### 稍后要回答的问题（此处先不作答）

1. 当前空的 `kernel_main` 会得到什么完整输出？返回后最终 `RIP` 停在哪里？
2. `CALL kernel_main` 前、刚进入 `kernel_main`、返回后，`RSP` 分别是多少？栈顶的 8 字节返回地址是多少？
3. 加入 `debug_putc('C');` 后，预测完整输出和最终 `RIP`。哪一项变化，哪一项不变？
4. 字符 `C` 的 ASCII 值是 `0x43`。按 ABI 和 `debug_putc` 的源码，说明它如何从 C 实参到达 I/O 端口。

## 1. 为什么现在终于可以把主线交给 C

CPU 不认识“C 函数”，只认识指令和机器状态。前 17 课看似漫长，实际是在建立 C 编译器默认不会替我们建立的前提：

| C 代码依赖的事实 | 当前由谁保证 |
|---|---|
| CPU 按 x86-64 指令解码 | long mode 与 `CS=0x18` |
| 函数机器码位于链接器认为的地址 | ELF + linker script |
| 取指和访问栈的地址已映射 | 低 2 MiB 恒等映射 |
| `CALL` 可以写栈 | `RSP=0x90000`，所在页可写 |
| 汇编和编译器同意参数/寄存器规则 | System V x86-64 ABI |

前四项已经完成。本课补上最后一项，然后立即转向 OS 主线。以后只有三类位置仍需少量汇编：异常/中断入口、上下文切换、系统调用入口；它们共同的原因都是 CPU 直接规定了入口时的寄存器和栈状态。

## 2. ABI 是两个编译单元之间的合同

C 源码中的函数声明：

```c
void debug_putc(char ch);
```

只告诉 C 编译器函数名、参数类型和返回类型。它没有说明机器层如何传参。System V x86-64 ABI 补上了这部分：前六个整数/指针参数依次使用 `RDI、RSI、RDX、RCX、R8、R9`，返回值通常使用 `RAX`，并规定哪些寄存器由哪一方保存。

因此这两段来自不同语言的代码可以拼在一起：

```text
C:   debug_putc('C')
           │
           │ 第一个整数参数放入 EDI/RDI，值为 0x43
           ▼
ASM: mov eax, edi → AL=0x43 → out 0xe9, al
```

如果汇编函数误以为第一个参数在 `RCX`，代码仍能链接，但运行行为会错。linker 只会解析符号，不会证明双方遵守同一个 ABI；这就是本课为什么既看反汇编，又验证真实输出。

### 2.1 栈对齐不是装饰

当前汇编入口在 `CALL` 前满足：

```text
RSP = 0x90000
RSP % 16 = 0
```

`CALL` 压入返回地址 `0x10019`：

```text
RSP = 0x8fff8
0x8fff8: 0x0000000000010019
```

所以 callee 入口看到 `RSP % 16 == 8`，符合 ABI。`RET` 后恢复到 `0x90000`。简单函数也许碰巧不使用对齐敏感指令，但入口必须先满足合同，否则函数一变复杂，编译器生成的合法代码就可能在错误环境中失败。

## 3. `freestanding`：这里没有 macOS 在背后托底

普通应用是 hosted 程序：操作系统加载它，运行时准备进程、栈和 C 库，然后调用约定入口。我们的内核正好相反——它自己将成为那个操作系统。

因此脚手架使用 `x86_64-elf-gcc -ffreestanding`：

- target 是 `x86_64-elf`，不是当前 Apple Silicon host。
- 不假设存在 `printf`、文件、进程或宿主 C 库。
- `kernel_main` 是课程自己调用的普通函数，不是操作系统替我们调用的 hosted `main`。
- `-fno-stack-protector` 避免在尚无对应 runtime 时插入 `__stack_chk_fail` 等依赖。
- `-mno-red-zone` 避免使用 `RSP` 下方 128 字节；以后异步中断入口会使用内核栈，不能沿用用户程序关于该区域不被打扰的假设。
- 暂时关闭 SIMD/MMX，是因为内核还没有建立和保存相应扩展状态的策略。

这些选项不作为背诵题。此刻只需掌握一个判断方法：**编译器可以生成什么代码，取决于我们承诺给它什么运行环境；内核必须显式缩小这些承诺。**

## 4. 汇编、C、linker 各负责什么

构建路径现在是：

```text
kernel/payload.asm ──nasm──────────▶ build/kernel.o
kernel/main.c       ──x86_64-elf-gcc▶ build/main.o
                                      │
                         linker script│ 解析 kernel_main/debug_putc
                                      ▼
                              build/kernel.elf
                                      │ objcopy -O binary
                                      ▼
                              build/kernel.bin
```

职责边界：

- assembler/compiler：把各自源文件变成 object，留下尚待解析的跨文件符号。
- linker：把两个 object 放进同一地址空间，修补 `call kernel_main` 和 `debug_putc` 的目标。
- `objcopy`：去掉 ELF metadata，生成 BIOS loader 真正搬运的 raw bytes。

当前 loader 仍只读一个 512 字节扇区，linker 会把载荷补齐到恰好 512 字节，并拒绝非空 `.bss`。这是有意保留的临时限制：本课只验证 C 调用，不顺带引入多扇区加载和 `.bss` 清零。它们会在后续内核运行环境中解决。

## 5. 不要把反汇编误当成 C 的逐行翻译

运行：

```sh
make inspect-kernel-c
```

它只展示汇编调用点、`kernel_main` 和 `debug_putc`，不会让 512 字节填充噪声淹没重点。

当前空函数会显示为一条 `ret`。完成练习后，编译器可能生成普通 `call debug_putc; ret`，也可能把函数末尾的调用优化成 `jmp debug_putc`（tail call）。两者都符合 C 语义和 ABI：后一种让 `debug_putc` 的 `ret` 直接返回原来的汇编调用者。

因此本课不要求机器码与某个样本逐字节相同，只要求三类证据同时成立：

1. ELF 中存在 `kernel_main` 和 `debug_putc`。
2. 汇编入口确实 `call kernel_main`。
3. 真实运行追加 `C`，随后回到固定的 `kernel_hang`。

## 6. 为什么一个 C 函数能跑，内核环境仍然不完整

当前的 `kernel_main` 只传递一个立即数字符、调用一次函数并返回。它没有读取全局变量，没有发生异常，也只使用了 8 字节返回地址。因此下面三项基础设施即使缺失，这条极窄的成功路径仍然可以运行；一旦程序使用到对应能力，缺口就会变成真实故障。

### 6.1 `.bss` 清零：C 语言对未显式初始化全局变量的承诺

下面的变量属于静态存储期：

```c
static unsigned page_count;
```

C 语言要求它在程序开始时等于 0。ELF 通常把这类变量放进 `.bss`：它们在运行时占内存，但不需要在文件里为大量零字节浪费空间。因此 loader 或汇编入口必须完成：

```text
把 [__bss_start, __bss_end) 对应的内存全部写成 0
```

当前 `kernel_main` 没有任何 `.bss` 变量，所以不清零也不影响输出 `C`。但以后若页帧分配器假设 `page_count` 初始为 0，而那片 RAM 恰好保留旧数据，C 语义就被破坏，计数和内存管理可能从随机值开始。当前 linker 用 `ASSERT(SIZEOF(.bss) == 0)` 暂时拒绝这种情况，而不是假装已经支持它。

### 6.2 IDT：CPU 发生异常后该把控制权交给谁

IDT（Interrupt Descriptor Table）把异常或中断 vector 映射到入口代码。例如：

```text
#DE 除零       → vector 0
#UD 非法指令   → vector 6
#PF 缺页       → vector 14
```

当前正确路径不除零、不执行非法指令，代码和栈也都已映射，所以没有异常需要递送；缺少有效 IDT 不妨碍这一行 C 碰巧成功。以后若访问未映射地址产生 `#PF`，CPU 必须通过 IDT 找到 handler。IDT 无效会让第一次异常无法递送，继续升级到 `#DF`；若 `#DF` 也无法递送，就会 triple fault，QEMU 外部通常只看到机器重启，得不到 fault address 和错误码。

### 6.3 stack guard：把栈越界从静默破坏变成可诊断错误

这里的 stack guard 指**页表层的保护页**，不要与编译器的 stack protector 混为一谈。常见做法是在栈边界放一页故意不映射的页面：

```text
高地址
┌────────────────┐
│ mapped stack   │  栈向低地址增长
├────────────────┤
│ unmapped guard │  越界访问触发 #PF
└────────────────┘
低地址
```

当前低 2 MiB 被一个大页整体映射，`RSP=0x90000` 周围没有未映射边界。一次 `CALL` 只写 8 字节，暂时安全；但深递归或巨大的局部数组可能让 `RSP` 一直向下越界，静默覆盖页表、代码或其他内核数据，而不是立即报错。有 stack guard 后，第一次跨界访问就产生 `#PF`；再配合有效 IDT，内核才能报告“kernel stack overflow”并停在可诊断现场。

三者的关系可以压缩为：

| 缺失项 | 极小函数为什么仍能跑 | 以后怎样暴露 |
|---|---|---|
| `.bss` 清零 | 当前没有未初始化全局变量 | 全局状态从垃圾值开始 |
| IDT | 当前成功路径不产生异常 | `#PF/#UD/#DE` 无法进入 handler，可能 triple fault |
| stack guard | 当前只使用一个返回地址 | 栈越界静默覆盖相邻内存 |

这也是“能输出一个字符”与“内核运行环境完整”的边界：前者只证明当前路径使用到的合同成立，不能证明尚未触发的合同也已经建立。

## 7. OS 视角：这一步在成熟系统里位于哪里

- xv6 的架构入口也先由少量汇编建立必要机器状态，再调用 C；进入 C 后，trap、进程和文件系统逻辑才成为主角。
- JOS 的早期入口同样把“CPU 必须要求的启动动作”和“C 内核初始化”分开。
- Linux 的真实入口复杂得多，但边界仍相同：架构相关汇编只负责把环境整理成 C 可以依赖的合同。

第 20–24 课会继续完善我们自己的 bootloader：多扇区加载、stage 1 / stage 2、E820 `boot_info`、ELF segment、`.bss`、内核栈与 ABI handoff 都会逐项闭环。毕业复盘之后才对照并切换成熟启动协议；今天学到的 ABI 边界会直接成为那份 handoff 合同的一部分。

## 红灯机制（先不要运行）

汇编入口已经输出 `K` 并按 ABI 调用 `kernel_main`，但当前 C 函数体为空，会立刻返回；所以控制流最终仍能回到 `kernel_hang`，唯独没有任何代码输出 `C`。本课检查器正是用这个缺失字符区分“成功进入 C”和“C 已实现目标行为”。

这里先理解红灯的代码和判定条件，不运行命令，也不查看真实输出。

## 实验前预测

现在已经读完 ABI、栈对齐、freestanding 环境和红灯成因。回到前面的“稍后要回答的问题”，
在第一次运行 `make check-c-kernel` 前把答案写入 `notes/05-C内核与Bootloader毕业/note-18.md`；
错误预测原样保留。

## 运行真实红灯

先运行：

```sh
make inspect-kernel-c
make check-c-kernel
```

当前 `kernel_main` 直接返回，所以汇编输出 `K` 后没有人输出 `C`。红灯应只包含：

```text
C-kernel check: kernel_main did not produce the expected observable behavior
C-kernel check: expected 'HelloPTLKC', got 'HelloPTLK'
C-kernel check: implement the single TODO in kernel/main.c
```

这时 `make check-kernel-entry` 仍然通过：CPU 确实进入载荷并最终停在 `0x1000e`。失败只表示 C 函数没有产生本课要求的可观察行为。

## 练习

打开 `kernel/main.c`，只完成一个 TODO：在 `kernel_main` 中调用已经声明的 `debug_putc`，输出字符 `C`。

约束：

- 只改 `kernel/main.c` 的函数体。
- 不写 inline assembly，不直接复制 `OUT` 指令。
- 不修改期望字符串、检查脚本、汇编入口或 linker script。
- 不需要自己写 `return`；返回类型是 `void`，运行到函数末尾会返回。

## 绿灯与取证

完成后运行：

```sh
make inspect-kernel-c
make check-c-kernel
make check-kernel-entry
make check-page-tables
```

预期关键证据：

```text
C-kernel check passed: assembly called kernel_main and received 'HelloPTLKC'
kernel-entry check passed: payload output begins 'HelloPTLK' and RIP=0x1000e under CS=0x18 (CS64)
```

`check-page-tables` 中 `PD[0]` 可能从 `0x00a3` 变成 `0x00e3`。多出的 `0x40` 是 Dirty 位：`CALL` 把返回地址写入映射在这个 2 MiB 大页中的栈。它是“C 调用确实使用了栈”的旁证，不是页表损坏。

## 观察题

1. `make inspect-kernel-c` 中，汇编调用 `kernel_main` 的指令地址和返回地址分别是什么？完成后 `kernel_main` 是普通 `CALL+RET`，还是 tail call？两者为何都可以？
2. 为什么必须用 `x86_64-elf-gcc` 和 freestanding 配置，而不能直接把这段代码当作普通 macOS 程序构建？
3. 为什么字符 `C` 与 `RIP=0x1000e` 要组合起来看？两项证据分别证明了什么？
4. 为什么本课允许没有 IDT、`.bss` 清零和 stack guard，却不能据此说“完整 C 内核环境已经建立”？各举一个以后会暴露问题的场景。

## 完成标准

- 四道实验前预测已在运行红灯前作答；错误答案原样保留。
- 只修改 `kernel/main.c` 的单个 TODO。
- `make check-c-kernel` 收到精确输出 `HelloPTLKC`。
- `make check-kernel-entry` 仍报告 `RIP=0x1000e`、`CS=0x18`（CS64）。
- 能解释第一个参数如何通过 `RDI` 到达 `AL`，以及 `RSP=0x90000 → 0x8fff8 → 0x90000`。
- 能区分“第一个 freestanding C 函数可运行”和“内核运行环境完整”。
