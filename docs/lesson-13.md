# 第 13 课：把执行权交给独立载荷

## 先修知识

开始前应理解：

- 第 11 课的结果：CPU 已在 IA-32e mode，`CS=0x18` 指向 GDT 第 3 项的 64 位 code descriptor，`CS.L=1`，指令按 64 位规则解码。
- 第 12 课的结果：`build/os.img` 的 LBA 1 已被 BIOS 读到 guest 物理地址 `0x10000`，那 512 字节以 `EB 08 'KERNEL64'` 开头。
- 低 2 MiB 是恒等映射（第 10 课），因此线性地址 `0x10000` 就落在物理帧 `0x10000`。
- `RAX/EAX/AX/AH/AL` 的重叠关系，见 [汇编底座](reference/assembly-basics.md)。
- 第 9、11 课用过的 far jump 写法 `jmp 0x08:protected_mode_entry`。

权威参考：

- [Intel SDM Volume 2](https://cdrdv2-public.intel.com/922478/325383-092-sdm-vol-2abcd.pdf)，`JMP` 指令页，注意 64-bit mode 一列。
- [Intel SDM Volume 1](https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf)，3.4.1.1 节：64 位模式下写 32 位寄存器会把高 32 位清零。
- [NASM 语言文档](https://www.nasm.us/doc/nasm03.html)，`strict` 关键字与立即数编码选择。

## 本课只引入一个机制

**把执行权从启动扇区转移到独立编译的载荷。**

这一课不新增任何 CPU 模式、不碰页表、不碰 GDT、不碰磁盘。唯一的新东西是一次跳转，以及“为什么本课选择绝对间接形式来完成它”。

## 实验输入：稍后预测会用到

下面先给出实验涉及的源码和地址。此处只阅读，**暂时不要作答，也不要运行命令**；继续读完跳转机制与红灯成因后，讲义会明确提示填写预测。

### 输入 A：启动扇区当前的 64 位入口

`long_mode_entry` 固定从 `0x7d30` 开始，当前源码是：

```asm
bits 64
long_mode_entry:
    mov al, 'L'
    out 0xe9, al

    times 4 db 0x90

.long_mode_hang:
    jmp .long_mode_hang
```

`times 4 db 0x90` 是汇编期伪指令：它连续生成四个 `90` 字节；CPU 会把每个 `0x90` 解码成一条 1 字节 `NOP`。预测时可以使用这些已知长度：

```text
mov al, imm8          2 字节
out imm8, al          2 字节
NOP                   1 字节
短跳转 jmp .label     2 字节
```

在进入这段代码之前，debug console 已经依次收到 `HelloPT`。

### 输入 B：已经加载到 `0x10000` 的载荷

常量 `KERNEL_LOAD_ADDR=0x10000`。第 12 课已经证明下面 512 字节载荷位于该地址，但当前启动扇区还没有跳过去：

```asm
bits 64
org 0x00010000

kernel_start:
    jmp short kernel_entry       ; 2 字节

kernel_magic:
    db 'KERNEL64'                ; 8 字节数据

kernel_entry:
    mov al, 'K'                  ; 2 字节
    out 0xe9, al                 ; 2 字节
.hang:
    jmp .hang                    ; 2 字节
```

你还可以使用前面课程已经建立的事实：

- 低 2 MiB 恒等映射，所以线性地址 `0x10000` 会访问物理地址 `0x10000`。
- 当前 `CS=0x18`，CPU 已按 64 位规则解码指令。
- `RAX/EAX/AX/AH/AL` 是同一寄存器的重叠视图；修改 `AL` 只改变最低 8 位。
- near jump 只改变当前指令流中的 offset/RIP；第 9、11 课使用 far jump，是因为当时还需要重新加载 `CS`。

### 稍后要回答的问题（此处先不作答）

第 4 题涉及后文讲解的 NASM 编码选择；读完正文后再回答。第 7 题不要求手工解码 magic，只要求根据取指规则判断 CPU 会如何看待那些字节。

1. 从当前四个 NOP 开始，预测红灯会输出什么完整字符串，`RIP` 最终会停在启动扇区的哪个地址？写出你推演的取指路径。
2. 假设只把四个 NOP 换成 `mov rax, KERNEL_LOAD_ADDR` 和 `jmp rax`：预测 CPU 此后依次会取哪些地址的指令，最终输出什么、停在哪里？
3. 上述跳转前后 `CS` 会不会变化？预测它的 selector 和解码模式，并说明依据。
4. `mov rax, 0x10000` 加 `jmp rax` 在你心中会生成多少字节？分别写出两条指令的预测长度；这里允许纯猜测。
5. 预测载荷输出 `K` 后的完整 `RAX`。请从“跳转前装入的地址”和“随后只修改 `AL`”两步推演。
6. 如果目标误写成 `0x1000a` 而不是 `0x10000`，预测 `HelloPTLK`、最终 `RIP` 和现有测试是否仍可能与正确实现完全相同。为什么？
7. 如果目标误写成 `0x10002`，CPU 会把 `KERNEL64` 当作数据还是指令？你预测可能出现正常输出、异常还是错误字符？先记录直觉，不要求手工完成全部指令解码。
8. 在“`K` 已输出”和“monitor 显示 `RIP` 正停在载荷中”两项证据里，你预测哪一项更强？各自仍排除不了什么情况？

## 1. 为什么"载荷已在内存"不等于"载荷在运行"

第 12 课结课时，`make check-kernel-load` 证明的是：

```text
物理地址 0x10000 处的两个 qword = 0x4c454e52454b08eb, 0xfeebe9e64bb03436
```

这是**数据证据**。它证明 BIOS 把字节搬到了 RAM，但它对"CPU 有没有从那里取过指令"一无所知。把那 512 字节换成一段无意义的数据，这条检查依然会通过。

真正能区分"字节在内存"和"CPU 在执行"的证据只有一类：**控制流证据**。本课用两个：

1. 端口 `0xe9` 出现第 9 个字符 `K`。载荷在 `0x1000a` 把 `K` 写入 `AL`，随后由 `0x1000c` 的 `out` 输出；当前启动扇区中没有会追加这个 `K` 的控制流。
2. `RIP` 停在 `0x1000e`。那是载荷自己的死循环地址。

第二条比第一条强。第一条只证明"载荷的某条指令被执行过"，第二条证明"CPU 现在正待在载荷里"。

载荷源代码中只有四条 CPU 指令，中间夹着一段数据：

```text
地址范围          类型       内容
0x10000..0x10001  指令       jmp short kernel_entry
0x10002..0x10009  数据       db 'KERNEL64'
0x1000a..0x1000b  指令       mov al, 'K'
0x1000c..0x1000d  指令       out 0xe9, al
0x1000e..0x1000f  指令       jmp .hang
```

裸二进制没有 ELF section、符号或“这里是数据”的元信息。如果让 `ndisasm` 从头一路解码，它会把 `KERNEL64` 的字节也解释成看似合法的指令。那不是 CPU 实际会走的路径：第一条 `EB 08` 已跳过这 8 字节。`make disassemble-kernel` 因此分三段展示入口指令、magic 原始字节和 `kernel_entry` 代码，避免把数据误认成指令。

## 2. x86-64 的 near `jmp imm` 永远是相对的

最直觉的写法是：

```asm
jmp KERNEL_LOAD_ADDR        ; 看起来像"跳到 0x10000"
```

它能工作。但它的机器码不是"0x10000"，而是一个**位移量**。

### 2.1 用机器码证明

把这段代码单独汇编（`bits 64`，指令位于地址 0）：

```asm
bits 64
    jmp 0x10000
```

得到：

```text
00000000  E9FBFF0000        jmp 0x10000
```

`E9` 是 `JMP rel32`，后面四个字节是小端序的 `0x0000FFFB`。验算：

```text
下一条指令地址  0x0 + 5 = 0x5
0x5 + 0xfffb             = 0x10000
```

CPU 算的是 `RIP + rel32`。汇编器只是替你做了减法。**这条指令里根本没有出现过 `0x10000` 这个数**。

这条指令的字节取决于它自己所在的地址：如果代码布局变化，汇编器会自动重新计算位移。因此 `jmp KERNEL_LOAD_ADDR` 在当前布局中是完全正确且不脆弱的写法；它真正的体系结构限制是目标必须位于下一条指令的 ±2 GiB 范围内。

### 2.2 rel32 的 ±2 GiB 边界

`rel32` 是有符号 32 位，范围约 ±2 GiB。现在跳 `0x7d30 → 0x10000` 只有几十 KiB，绰绰有余。但本课程后面要把内核放到高半区，典型地址是：

```text
0xffffffff80000000
```

从 `0x7d30` 到那里所需的有符号位移超出 rel32 范围，`JMP rel32` **无法表达**。届时必须换成间接跳转。本课提前练习间接形式，是为后面的高半区映射准备一种必要工具；这不表示当前的相对写法是错误的。

顺带说明：`bits 64` 下也有 `JMP rel8`（`EB`），范围 ±128 字节，载荷内部的 `jmp short kernel_entry` 用的就是它。同样是相对的。

## 3. 绝对间接跳转

64 位模式没有"绝对直接 near jump"这种指令 —— 没有 `JMP imm64`。要表达绝对目标，必须让地址先落在寄存器或内存里，再间接跳：

```asm
mov rax, KERNEL_LOAD_ADDR
jmp rax                     ; FF E0，JMP r/m64
```

`FF E0` 拆开看：`FF /4` 是 `JMP r/m64`，ModRM 字节 `E0 = 11 100 000`，`mod=11`（操作数是寄存器）、`reg=100`（/4 选中 JMP）、`rm=000`（RAX）。

也可以从内存间接跳：

```asm
mov rax, [rel kernel_entry_ptr]
jmp rax
```

### 3.1 `mov rax, imm` 有三种编码，NASM 会替你选

这是本课最容易看错的地方。同样写 `mov rax, ...`，实测机器码是：

```text
mov rax, 0x10000              → B8 00 00 01 00                 (5 字节，其实是 mov eax)
mov rax, strict qword 0x10000 → 48 B8 0000010000000000         (10 字节，movabs)
mov rax, 0xffffffff80000000   → 48 C7 C0 00 00 00 80           (7 字节，imm32 符号扩展)
mov rax, 0xffff800000000000   → 48 B8 000000000000 80 FF FF    (10 字节，movabs)
```

第一行是重点：你写的是 `rax`，NASM 发的是 `mov eax, 0x10000`。这不是 NASM 偷懒，而是合法优化 —— **64 位模式下写 32 位寄存器会把高 32 位清零**，而 `0x10000` 装得进 32 位，所以 5 字节的 `mov eax` 和 10 字节的 `movabs` 结果完全一样，前者更短。

第三行说明为什么"高半区地址一定要 movabs"是个不准确的说法：`0xffffffff80000000` 能由 imm32 符号扩展得到，只要 7 字节。真正需要 10 字节 movabs 的是第四行那种既装不进 32 位、又不是 imm32 符号扩展结果的地址。

练习时你会在反汇编里看到自己实际产生了哪一种。**记录你看到的，不要记录你以为的。**

### 3.2 为什么本课选择绝对间接

`jmp KERNEL_LOAD_ADDR`（rel32）在今天的布局下同样正确，也能跑到绿灯，测试无法区分两者。本课仍选择绝对间接，是一个教学约束：

- 可以直接从 `mov` 的立即数观察载荷入口契约 `0x10000`，再区分“准备目标地址”和“间接改变 RIP”两个动作。
- 后面的高半区入口可能超出 rel32 范围，届时必须掌握间接跳转。
- 反汇编里出现 `mov eax,0x10000` / `jmp rax`，读代码的人能直接看到目标地址；看到 `E9 <rel32>` 则要用下一条指令地址加上有符号位移还原目标。

## 4. 为什么不需要 far jump

第 9 课进保护模式、第 11 课进 long mode，都用了 far jump，因为那两次都必须**重新加载 `CS`**：前者让 `CS.D` 从 0 变 1，后者让 `CS.L` 从 0 变 1。

这一课不改变任何模式。载荷也是 64 位代码，跟启动扇区共用同一个 code descriptor（selector `0x18`）。`CS` 不需要变，所以 near jump 就够了。

而且 64 位模式里那种写法**根本不存在**。把第 9 课的形式放进 `bits 64` 试一下：

```asm
bits 64
jmp 0x18:0x10000
```

NASM 直接报错：

```text
error: instruction not supported in 64-bit mode
```

原因是直接 far jump 的 opcode `EA`（`JMP ptr16:32`）在 64-bit mode 被定义为无效。64 位下唯一的 far jump 是间接形式 `JMP m16:64`：

```text
48 FF 2D ...      jmp qword far [rel ...]
```

它从内存读 64 位 offset 加 16 位 selector。本课不需要它。

因此"`CS` 在跳转前后保持 `0x18`"是一条可断言的不变量 —— 它同时证明了"控制权转移了"和"没有发生段切换"。

## 5. 为什么是单向交接，不用 `call`

`call` 隐含"载荷会返回"，而返回需要双方约定：谁拥有栈、哪些寄存器由被调用方保存、返回值放哪里。现在什么都还没约定：

- `RSP=0x90000` 是启动扇区在第 9 课随手选的，载荷并不知道这个值，也没有自己的栈。
- 载荷是 `nasm -f bin` 的裸二进制，没有链接脚本、没有节、没有符号。
- 双方没有共用的调用约定。

那些正是后面几课的内容：linker script、System V x86-64 ABI、栈对齐、清零 `.bss`。在此之前，交接必须是单向的：跳过去，不回来。载荷末尾的死循环就是这个语义的体现。

## 6. 本课为什么不校验 `KERNEL64`

载荷开头留了 8 字节 magic，用途是"跳之前先确认这里真的是我要的载荷"。健壮的 bootloader 会做这件事。本课刻意不做，理由是每课只引入一个机制：本课要证明的是控制流转移，加入校验会让红灯同时可能由"校验逻辑写错"和"跳转写错"两种原因引起，失败信息就不再唯一。

也正因为没有校验，`jmp` 的目标必须是 `0x10000` 而不是 `0x1000a`：载荷第一条指令 `jmp short kernel_entry`（`EB 08`）的作用就是跳过那 8 字节 magic。让载荷自己决定如何跨过自己的头部，启动扇区不需要知道 magic 有多长。

## 7. 为什么这一课要先改六个测试脚本

打开 `git diff` 会看到本课脚手架动了六个旧脚本。这不是练习内容，但值得理解，因为它是一类常见的测试设计缺陷。

`check-a20`、`check-gdt`、`check-protected`、`check-page-tables`、`check-long-mode`、`check-kernel-load` 都要先等启动流程跑完，再去查寄存器或物理内存。它们原来的等待条件是：

```zsh
[[ "$(< "$output_file")" == "$expected_output" ]]      # 精确相等
```

也就是用**完整输出等于某个串**来判断"可以查状态了"。这在每一课都能成立，直到有一课往输出末尾追加字符 —— 本课追加了 `K`。于是这六个脚本会因为 `HelloPTL != HelloPTLK` 集体超时失败，而它们要断言的 A20、GDT、CR0.PE、页表、long mode 其实全都好着。

红灯必须只由本课机制缺失引起，所以这里把**同步条件**和**断言条件**分开：

```zsh
[[ "$(< "$output_file")" == "$expected_output"* ]]     # 前缀匹配
```

Makefile 也相应分成两个变量：

```make
DEBUGCON_EXPECTED := HelloPTLK    # 完整输出，只有 check-debugcon 和 check-kernel-entry 精确断言
BOOT_SYNC_PREFIX  := HelloPTL     # 六个旧检查只用它同步到"切换序列已完成"
```

`check-debugcon` 保持精确相等 —— 它的职责本来就是断言输出内容本身，所以本课它也会红，而且**应该**红。

## 红灯机制（先不要运行）

当前 `long_mode_entry` 输出 `L` 后执行四个 NOP，随后落入启动扇区自己的死循环；它从未把 `RIP` 改到 `0x10000`。因此磁盘加载检查仍可通过，但载荷不会输出 `K`，控制流检查也会确认 CPU 仍停在启动扇区。

这里先理解“已加载但未执行”的红灯因果，不运行命令，也不查看真实输出。

## 实验前预测

现在已经读完绝对间接跳转、载荷入口、测试同步方式和红灯成因。回到前面的“稍后要回答的问题”，
在第一次运行 `make check-kernel-entry` 前把答案写入 `notes/03-加载交接与ELF/note-13.md`；
错误预测原样保留。

## 运行真实红灯

先运行：

```sh
make disassemble-kernel
make check-debugcon
make check-kernel-entry
```

第一条证明载荷的机器码长什么样。后两条应失败。

`make check-debugcon` 的红灯：

```text
debug console: expected 'HelloPTLK', got 'HelloPTL'
```

`make check-kernel-entry` 的红灯：

```text
kernel-entry check: the payload never wrote its own character to port 0xe9
kernel-entry check: expected debug output 'HelloPTLK', got 'HelloPTL'
kernel-entry check: RIP is not parked in the payload hang loop
kernel-entry check: expected RIP=000000000001000e (kernel/payload.asm .hang)
kernel-entry check: actual RIP=0000000000007d38
```

红灯时 `long_mode_entry` 里是四个 NOP 占位，随后落进自己的死循环：

```text
== 64-bit long-mode entry and payload handoff (0x7d30-0x7d4f) ==
00007D30  B04C              mov al,0x4c
00007D32  E6E9              out byte 0xe9,al
00007D34  90                nop
00007D35  90                nop
00007D36  90                nop
00007D37  90                nop
00007D38  EBFE              jmp 0x7d38
```

所以红灯时 `RIP=0x0000000000007d38` —— 仍在启动扇区里。同时注意：

- `make check-kernel-load` 仍应通过。字节确实在 `0x10000`，本课缺的不是加载。
- `make check-a20`、`check-gdt`、`check-protected`、`check-page-tables`、`check-long-mode` 仍应全部通过。红灯只由"没有交接"引起。

这四个 NOP 只是标记位置，**它的长度不是答案的长度**，你要自己数自己写出的字节数。

## 练习

打开 `boot/boot.asm`，只修改 `long_mode_entry` 中带 `RED`/`TODO` 的四字节占位：

1. 把 `KERNEL_LOAD_ADDR` 装进一个 64 位通用寄存器。
2. 用 `JMP r/m64` 间接跳过去。不要用 far jump，不要用 `jmp KERNEL_LOAD_ADDR` 的相对形式。
3. 目标是 `0x10000`，不是 `0x1000a`。让载荷自己跳过 magic。
4. 不要修改 `kernel/payload.asm`、固定地址布局和旧课代码。
5. 占位下面原有的 `.long_mode_hang` 保留不动：红灯阶段四个 NOP 会自然落入它，所以我们能观察到 `RIP=0x7d38`。正确的无条件跳转不会再执行它；如果目标无效，CPU 会产生异常，也不会“失败后落到下一条指令”。

看自己写出的 64 位机器码：

```sh
make disassemble-boot
```

完成后运行：

```sh
make check-kernel-entry
make check-debugcon
make check-kernel-load
make check-segments
make check-call
make check-a20
make check-gdt
make check-protected
make check-page-tables
make check-long-mode
```

## 观察题

1. 载荷四条 CPU 指令的地址各是什么？magic 数据占据什么地址范围？`EB 08` 的位移 `08` 是怎么算出来的？
2. 绿灯时 `RIP` 是多少？为什么这个值比"输出了 `K`"更能证明 CPU 正在载荷里？
3. 绿灯时 `CS` 的完整一行是什么？它相比第 11 课有没有变化，说明了什么？
4. 你写的两条指令的机器码各是什么？`mov` 一共几字节，NASM 选了 §3.1 里的哪一种编码？为什么可以这样选？
5. 绿灯时 `RAX` 是 `0x000000000001004b`。请解释这个值的每一部分是怎么来的。
6. 把实现改成 `jmp KERNEL_LOAD_ADDR`，反汇编看机器码。它是什么 opcode？位移是多少？验算一遍。测试还通过吗？为什么这仍然不是本课要的写法？（记录完把实现改回来）
7. 在 `bits 64` 区域写 `jmp 0x18:0x10000` 会发生什么？为什么？64 位模式下唯一可用的 far jump 是什么形式？
8. 为什么这次交接用 `jmp` 而不是 `call`？如果改成 `call`，缺的是哪几项约定？

## 完成标准

- `make check-kernel-entry` 报告 payload 正在 `0x1000e` 执行，且 `CS=0x18`（`CS64`）。
- `make check-debugcon` 报告收到完整的 `HelloPTLK`。
- 能用机器码说明 `JMP rel32` 是相对跳转，并解释为什么它表达不了高半区地址。
- 能说明 `mov rax, imm` 的三种编码，以及自己产生的是哪一种、为什么。
- 能解释为什么本课不需要 far jump，以及 64 位模式下直接 far jump 为何不存在。
- 原有启动扇区、镜像布局、实模式寄存器、调用栈、A20、GDT、保护模式、页表、long mode 和 kernel-load 测试全部回归通过。
