# 第 23 课：让 stage 2 真正按 ELF 装载内核

> 一句话任务：第 22 课已经让 stage 2 把内存图交给 C；这一课继续把“装载 kernel”也迁进 stage 2，并补上 ELF 要求的 `.bss` 清零。ELF parser 和栈入口都已给好，你只补一条清零指令。

## 0. 从第 22 课结束的位置继续

先不要看 ELF 字段。我们先恢复第 22 课结束时的真实控制流。

### 第 20 课：stage 1 直接加载 raw kernel

第 20 课把 `kernel.bin` 扩大到 4 sectors。stage 1 使用 BIOS 把它从 LBA 1..4 原样搬到 `0x10000..0x107ff`：

```text
LBA 1..4 的 kernel.bin
        │ stage 1 / INT 13h
        ▼
RAM 0x10000..0x107ff
        │ 进入 long mode 后固定跳到 0x10000
        ▼
kernel
```

这时 `kernel.elf` 只在构建和调试阶段使用。bootloader 真正读取的是已经去掉 ELF header 的 `kernel.bin`。

### 第 21 课：增加 stage 2，但还没有迁移 kernel loader

第 21 课只证明了 stage 2 能被加载、执行并返回：

```text
stage 1 加载 kernel.bin
stage 1 加载 stage2.bin
stage 1 CALL stage 2
stage 2 写 STAGE2OK 后 RET
stage 1 继续模式切换并跳到 kernel
```

当时讲义结尾明确留下两个缺口：

- kernel 仍由 stage 1 按固定扇区加载；
- stage 2 还不解析 ELF。

### 第 22 课：先把 E820 职责迁进 stage 2

第 22 课让 stage 2 调 BIOS E820，并把 `boot_info` 放到 `0x5000`。stage 2 返回后，stage 1 进入 long mode，用：

```text
RDI = 0x5000
```

把 `boot_info` 交给 C。

但第 22 课没有改变 kernel 的装载方式：kernel bytes 仍然来自 stage 1 固定读取的 raw `kernel.bin`。

### 第 23 课：迁移最后一项与内核直接相关的加载职责

这一课把上面的旧链路改成：

```text
BIOS 自动加载 stage 1
        │
        ▼
stage 1 只加载并 CALL stage 2
        │
        ▼
stage 2 查询 E820
        │
        ├─ 读取 kernel ELF 到临时区 0x20000
        ├─ 按 PT_LOAD 把 kernel 放到运行地址
        ├─ 清零文件中不存在的 .bss
        └─ 把 ELF entry 写入 boot_info
        │ RET
        ▼
stage 1 进入 long mode
        │ RDI = boot_info，RAX = ELF entry
        ▼
kernel 设置自己的栈并 CALL C
```

这正是第 21 课未完成清单的延续，不是突然增加一条新的旁支。

## 1. 这一课你到底要做什么

先把“脚手架做什么”和“你做什么”分开：

| 部分 | 谁完成 | 你是否需要编写 |
| --- | --- | --- |
| 从磁盘读取精简 ELF | 脚手架 | 否 |
| 校验 ELF64/x86-64 header | 脚手架 | 否 |
| 遍历 `PT_LOAD` | 脚手架 | 否 |
| 复制文件中存在的 kernel bytes | 脚手架 | 否 |
| 从 ELF 读取动态 entry | 脚手架 | 否 |
| 建立 16 KiB 专用内核栈 | 脚手架 | 否 |
| 清零 `p_memsz - p_filesz` | **你** | **是，只补一条指令** |

你的学习流程只有四步：

1. 读懂旧 raw loader 为什么不能建立 `.bss` 合同。
2. 根据给出的两个 `PT_LOAD` 完成三组预测。
3. 运行红灯，确认“代码已加载”和“`.bss` 未清零”能同时成立。
4. 在 lesson-23 TODO 下补一条 string instruction，再跑绿灯。

你不需要从零写 ELF loader，不需要背 program-header 字段 offset，也不需要修改 linker script、C 代码或检查器。

## 先修知识

只需记住前文的三个结论：

- 第 14 课：`kernel.elf` 带加载信息，`kernel.bin` 只是抽出的 raw bytes。
- 第 18 课：调用 C 前需要满足 System V x86-64 ABI；第一个参数放在 `RDI`，栈需要对齐。
- 第 22 课：stage 2 已能产生 `boot_info`，并通过 `RDI=0x5000` 交给 C。

本课仍是加速轨道 bridge 章节。深入参考放在这里，遇到调试需要时再查：

- [System V ABI：Program Loading](https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html)
- [System V x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI)
- [GNU ld：PHDRS](https://sourceware.org/binutils/docs/ld/PHDRS.html)

## 2. 为什么不能继续只搬 `kernel.bin`

raw loader 的规则非常简单：

```text
把磁盘上的 2048 bytes 搬到 0x10000
然后跳到 0x10000
```

它能让当前小内核运行，但只能表达“文件里有的 bytes”。它回答不了：

- 哪些 bytes 应该复制到哪个地址？
- 哪一段运行时需要内存，但文件里不应保存同样多的零？
- 内核真正的 entry 是什么？
- 如果以后有多个可加载区域，应该怎样分别处理？

可以把两种产物理解成：

```text
kernel.bin       = 一箱没有说明书的连续 bytes
kernel.load.elf  = bytes + 一张装载清单
```

旧 loader 只会把整箱放到固定地址。ELF loader 会读取“装载清单”，按清单逐项建立运行时内存。

### 为什么还保留 `kernel.bin`

当前镜像仍把历史 `kernel.bin` 放在 LBA 1..4，只为了让第 20 课的旧字节检查继续有参照。第 23 课的启动路径不再读取它。

真正供 stage 2 使用的是：

```text
build/kernel.load.elf
```

它仍是标准 ELF，只移除了 loader 不需要的 symbol/debug 信息。它位于镜像 LBA 18 起始位置。

## 3. `PT_LOAD` 就是一条“怎样建立内存”的配方

ELF 中有 section headers 和 program headers：

- `.text`、`.data`、`.bss` 等 section 主要服务 linker、debugger 和反汇编工具；
- `PT_LOAD` program header 主要服务 loader。

stage 2 不需要按名字寻找 `.text` 或 `.bss`。它只需对每个 `PT_LOAD` 执行同一条规则：

```text
第一步：从 ELF 的 p_offset 处复制 p_filesz bytes 到 p_paddr
第二步：从目标末尾继续清零 p_memsz - p_filesz bytes
```

四个字段的直白含义是：

| 字段 | 本课只需这样理解 |
| --- | --- |
| `p_offset` | 这段 file bytes 在 ELF 文件中的起点 |
| `p_paddr` | loader 应把它放到的物理地址 |
| `p_filesz` | 文件实际提供多少 bytes |
| `p_memsz` | 运行时总共需要多少 bytes |

### 先看一个与本课数值无关的小例子

假设一条配方是：

```text
p_offset = 0x200
p_paddr  = 0x8000
p_filesz = 4
p_memsz  = 10
```

loader 要做的是：

```text
file[0x200..0x204) → memory[0x8000..0x8004)
memory[0x8004..0x800a) = 0
```

也就是复制 4 bytes，再补 6 个零。注意区间采用左闭右开写法，最后一个被清零的地址是 `0x8009`。

这就是本课唯一的新算法。

## 4. 本课给出的两条实际配方

脚手架产生两个 `PT_LOAD`。下面是实验前已经完全给出的输入：

| 项 | `p_offset` | `p_paddr` | `p_filesz` | `p_memsz` | 用途 |
| --- | ---: | ---: | ---: | ---: | --- |
| LOAD 0 | `0x1000` | `0x10000` | `0x800` | `0x800` | 已存在于文件中的代码、数据和旧尾标记 |
| LOAD 1 | `0x1000` | `0x11000` | `0` | `0x4008` | 文件中不占 bytes、运行时必须存在的 `.bss` |

stage 2 先把整个 ELF 读到 scratch 起点 `0x20000`，因此某段 file bytes 的实际 source address 是：

```text
scratch base + p_offset
```

请先不要在这里看实验输出。稍后的预测题只要求把上面四个字段代入第 3 节的两步规则。

### 为什么 LOAD 1 的 `p_filesz=0`

LOAD 1 对应 `.bss`。C 中这个未显式初始化的全局变量位于其中：

```c
volatile uint64_t lesson23_bss_probe;
```

C 语言要求它在 `kernel_main` 开始前等于零，但没有必要在 ELF 文件里保存成千上万个零。因此 ELF 只声明“运行时需要 `0x4008` bytes”，把补零责任交给 loader。

`p_filesz=0` 时不会执行 file copy；此时 `p_offset` 的具体值不会产生 source 读取。loader 仍必须处理非零的 `p_memsz`。

## 5. 为什么 `.bss` 里还放了内核栈

本课的 `.bss` 内存布局是：

```text
0x11000  kernel_stack_bottom
          16 KiB 专用内核栈
0x15000  kernel_stack_top
0x15000  lesson23_bss_probe
0x15008  __bss_end
```

栈只需要运行时内存，不需要在磁盘文件里保存 16 KiB 零，所以也很适合放进 file size 为 0、memory size 非零的 load segment。

ELF loader 建立这段内存后，kernel 汇编入口执行：

```asm
lea rsp, [rel kernel_stack_top]
and rsp, -16
xor ebp, ebp
call kernel_main
```

这段入口由脚手架提供。它延续第 18 课的 ABI：

```text
CALL 前：RSP % 16 == 0
CALL 压入 8-byte return address
C 入口：RSP % 16 == 8
第一个 C 参数仍是 RDI = 0x5000
```

设置新 `RSP` 不会修改 `RDI`，所以第 22 课的 `boot_info` 仍然能到达 C。

专用栈不等于 stack guard。当前低 2 MiB 都可写，栈溢出仍可能静默破坏相邻内存；这里只建立栈的位置、所有权和 ABI 合同。

## 6. ELF entry 如何接到第 22 课的 `boot_info`

第 22 课的 `boot_info` 是 bootloader 到 kernel 的参数结构。本课没有另造一套 handoff，而是使用原来预留的最后 8 bytes：

```text
boot_info base                  = 0x5000
kernel_entry_phys field offset  = 24 = 0x18
字段地址                        = 0x5018
```

stage 2 从 ELF header 读取 `e_entry`，写到 `0x5018`。进入 long mode 后：

```asm
mov edi, 0x5000          ; 第 22 课：C 的第一个参数
mov rax, [abs 0x5018]    ; 第 23 课：从 ELF 得到的 kernel entry
jmp rax
```

当前 ELF 的 `e_entry` 仍是 `0x10000`，但这个值现在来自 ELF metadata，而不是写死在 bootloader 的 `mov rax,0x10000` 中。

## 7. 本课怎样证明“真的用了 ELF”

只检查 `0x10000` 出现 `KERNEL64` 还不够，因为镜像 LBA 1..4 仍保留历史 `kernel.bin`。检查器会制作一个临时镜像副本，然后：

```text
把临时副本的 LBA 1..4 清零
保留 LBA 18 起始的 kernel.load.elf
启动 QEMU
```

如果完整 kernel 仍能运行，就能排除“stage 1 偷偷继续读取 raw kernel”的可能。

检查器还观察：

| 证据 | writer / 来源 | observer | 证明什么 |
| --- | --- | --- | --- |
| `0x20000` 的 ELF magic | stage 2 磁盘读取 | host checker | ELF 到达 scratch |
| `0x5018` 的 entry | stage 2 解析 ELF | host checker | entry 已加入原有 boot-info handoff |
| `.bss` probe | loader 建立、C 读取 | host checker | zero-fill 是否成立 |
| `ELF64OK!` at `0x7018` | 64 位 C | host checker | C 观察到零 `.bss` 且运行在专用栈 |

`ELF64OK!` 是课程测试回执，不是 ELF 标准字段。它与第 22 课的 `E820COK!` 分开：

- `E820COK!` 证明 C 消费了内存图；
- `ELF64OK!` 证明 C 消费了 ELF loader 建立的运行环境。

## 8. 红灯缺的到底是哪一步（先不要运行）

脚手架已经完成：

```text
读 ELF → 校验 → 遍历 PT_LOAD → copy p_filesz → 发布 e_entry
```

为了避免 QEMU 初始 RAM 恰好为零造成假绿灯，代码先把需要清零的范围故意写成 `0xA5`：

```asm
; 此前 rep movsb 已经完成 p_filesz 的 file copy。
mov cx, [ds:bp + 40]   ; CX = p_memsz
sub cx, [ds:bp + 32]   ; CX = p_memsz - p_filesz
mov dx, cx              ; 保存长度

mov al, 0xa5
rep stosb               ; 课程故障注入：先把目标范围写成 A5

sub di, dx              ; DI 回到这段范围的起点
mov cx, dx              ; CX 恢复为待清零长度
xor al, al              ; AL = 0
; RED / TODO (lesson 23): 用一条 string instruction 写入 CX 个零
```

到 TODO 时，所有输入都已准备好：

```text
ES:DI = 待清零区间起点
AL    = 0
CX    = p_memsz - p_filesz
DF    = 0，地址递增
```

你只需补一条“重复写 byte”的 NASM string instruction。它的相同语法就在上面的故障注入中，任务不是猜 opcode。

## 实验前预测

现在再打开 `notes/05-C内核与Bootloader毕业/note-23.md`。
第一次运行命令前完成下面三组；错误答案保留，实验后另写修正。

### 1. 把两个 `PT_LOAD` 翻译成内存动作

根据第 4 节表格计算：

- LOAD 0 的 source 起点、destination 区间、zero length；
- LOAD 1 的 copy length、zero interval、最后一个 zero byte 地址。

### 2. 当前红灯会留下什么

根据第 8 节的 `0xA5` 故障注入和缺失的清零步骤，预测：

- `lesson23_bss_probe` 的 8-byte qword；
- `0x7018` 的 acknowledgement qword；
- 为什么 kernel 代码仍可能输出完整的 `HelloPTLKCUR`。

### 3. 第 22 课 handoff 如何继续工作

计算并解释：

- `boot_info.kernel_entry_phys` 的地址；
- `CALL kernel_main` 前和 C 入口的 `RSP`，以及各自对 16 取模；
- 临时清零 raw LBA 1..4 后，kernel bytes 和 jump target 分别来自哪里。

## 9. 实验：你现在按什么顺序操作

### 第一步：先看静态输入

完成预测后运行：

```sh
make inspect-elf-loader
```

在笔记里只记录：

- 两个 `PT_LOAD`；
- `rep movsb`、`0xA5` 故障注入和 TODO 的相对位置；
- `.bss`、stack 和 probe symbols。

### 第二步：运行真实红灯

```sh
make check-elf-loader
```

红灯的核心应该是：

```text
file-backed kernel 已经从 ELF 加载并执行
但是 NOBITS/.bss 仍保留故障注入值
所以 C 不写 ELF64OK!
```

这说明“代码能运行”和“C 运行环境完整”不是同一个结论。

### 第三步：只改一行

打开 `boot/stage2.asm`，定位：

```asm
; RED / TODO (lesson 23): zero the NOBITS tail with one string instruction.
```

在其下一行补一条指令，使 CPU 把 `CX` 个 `AL=0` 写到 `ES:DI`。

不要修改 poison、linker script、C 回执或 checker。

### 第四步：运行绿灯和旧回归

```sh
make check-elf-loader
make check-e820-boot-info
make check-multisector-load
make check-exception
```

## 10. 把整章压缩成一条因果链

学完后应该能说出：

```text
第 20 课的 raw loader 只会固定搬运文件 bytes
→ 第 21 课建立 stage 2 执行边界
→ 第 22 课把 E820/boot_info 放进 stage 2
→ 第 23 课让 stage 2 消费 ELF PT_LOAD
→ copy p_filesz 建立 file-backed 内容
→ zero p_memsz-p_filesz 建立 .bss 与专用栈内存
→ e_entry 通过原有 boot_info 抵达 long-mode jump
→ kernel 按 ABI 在自己的栈上调用 C
```

## 11. 简短的 OS 视角

本课的意义不在于记 ELF 字段。以后实现 `exec` 时，内核也要把用户 ELF 转换成运行时地址空间：复制 file-backed 部分、为 `.bss` 建立 zero-filled memory、设置用户栈和初始 entry。

这次 stage 2 做的是同一种“持久化表示 → 运行时内存对象”转换，只是目标从用户进程换成了内核本身。

## 仍然有意不实现的内容

教学 loader 只接受低端、16-byte-aligned、能放进当前 real-mode window 的 ELF segments。它暂不实现文件系统、任意 LBA、重定位、高半地址、签名验证、严格的段页权限或 stack guard。

这些会在第 24 课作为 bootloader 毕业边界明确记录，不是本课隐藏的练习。

## 观察题

1. 为什么 `.bss` 在 section table 中有名字，loader 仍应该消费 `PT_LOAD` 而不是按名字寻找它？
2. 为什么必须主动注入 `0xA5`，不能把 QEMU 初始 RAM 为零当作 loader 清零的证据？
3. 清零临时镜像的 raw LBA 1 后仍能运行，具体排除了哪一种错误实现？

## 完成标准

- 能从第 20–22 课自然说明为什么第 23 课要把 kernel loader 迁入 stage 2。
- 三组预测在第一次运行命令前完成，错误预测原样保留。
- 只在 lesson-23 TODO 补一条清零指令。
- `make check-elf-loader` 证明 raw LBA 1 被破坏后仍从 ELF 启动、`.bss` 为零且 C 使用专用栈。
- 能用自己的话解释 `copy p_filesz + zero (p_memsz-p_filesz)`。
- 三项旧回归继续通过。
