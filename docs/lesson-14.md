# 第 14 课：用 linker script 固定内核的 ELF 地址

## 先修知识

开始前应理解：

- 第 12 课把镜像 LBA 1 的 512 字节载荷读到物理地址 `0x10000`。
- 第 13 课在 `CS64` 下跳到 `0x10000`，最终停在 `RIP=0x1000e`。
- `ORG` 只影响 flat binary 中的地址计算，不负责加载。
- 标签代表地址；短跳转使用相对于下一条指令的位移。
- host 文件偏移、guest 物理地址和 CPU 的线性地址是不同坐标系。

本课第一次使用 ELF object、ELF executable、linker script、`SECTION` 和 `GLOBAL`。所需 NASM 语法已补到 [NASM 与 x86 寄存器入门](reference/assembly-basics.md#10-elf-sectionglobal-与链接)，linker script 则在本课逐项讲解。

权威参考：

- [GNU ld：Linker Scripts](https://sourceware.org/binutils/docs/ld/Scripts.html)
- [GNU ld：The Location Counter](https://sourceware.org/binutils/docs/ld/Location-Counter.html)
- [GNU objcopy](https://sourceware.org/binutils/docs/binutils/objcopy.html)
- [NASM：ELF32 and ELF64 Object File Formats](https://www.nasm.us/doc/nasm10.html)
- [System V ABI：ELF 格式](https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html)

## 本课只引入一个机制

**让 linker 而不是 `ORG` 决定内核符号的最终地址。**

我们会把构建管线从：

```text
payload.asm ── nasm -f bin ──▶ kernel.bin
```

升级为：

```text
payload.asm
    │ nasm -f elf64
    ▼
kernel.o                 relocatable ELF object
    │ x86_64-elf-ld -T kernel/linker.ld
    ▼
kernel.elf               linked ELF executable
    │ x86_64-elf-objcopy -O binary
    ▼
kernel.bin               BIOS loader 仍然读取的 512 字节 raw payload
```

本课不加入 C、不改变载荷行为、不增加扇区，也不让 bootloader 解析 ELF。唯一的练习是修正 linker script 中的链接地址。

## 实验前推演（尚未运行）：先停在这里

**第一次阅读时先不要继续向下看，也不要运行命令。** 这不是让你猜工具的隐藏行为：以下输入应足以推出每一题。如果某题仍无法由输入推出，应指出缺少哪条规则，而不是硬猜。

### 输入 A：新的构建管线

```text
kernel/payload.asm
  → build/kernel.o
  → build/kernel.elf
  → build/kernel.bin
  → build/os.img 的 LBA 1
  → BIOS INT 13h 读到 guest 物理地址 0x10000
```

`kernel.o` 和 `kernel.elf` 是 ELF 文件，所以它们都以 ELF magic `7f 45 4c 46` 开头；`kernel.bin` 是从 ELF 中抽出的 raw bytes，不带 ELF magic。bootloader 仍只读取 `kernel.bin`，不知道 ELF header、section table 或 symbol table 的存在。

本课当前只有一个 loadable section `.text`，大小为 512 字节。`objcopy -O binary` 会把最低 loadable section 的第一个字节放在 raw binary offset 0，并保留该 section 的内容；单独把这个 section 的 VMA 从 0 改成 `0x10000`，不会在文件前补 64 KiB 零。

### 输入 B：载荷的 section 和符号偏移

当前 `payload.asm` 不再使用 `ORG`：

```asm
bits 64
section .text
global kernel_start
global kernel_magic
global kernel_entry
global kernel_hang

kernel_start:                 ; .text + 0x00
    jmp short kernel_entry
kernel_magic:                 ; .text + 0x02
    db 'KERNEL64'
kernel_entry:                 ; .text + 0x0a
    mov al, 'K'
    out 0xe9, al
kernel_hang:                  ; .text + 0x0e
    jmp kernel_hang
```

整个 `.text` 仍被零填充到 `0x200 = 512` 字节。

### 输入 C：尚未修改的 linker script

```ld
ENTRY(kernel_start)

SECTIONS
{
    . = 0x00000000;

    .text :
    {
        *(.text)
    }
}
```

你可以使用三个事实：

- `.` 是 linker 的 location counter；输出 section 从它的当前值开始布置。
- 一个符号的最终值等于“输出 section 起始地址 + 符号在输入 section 内的偏移”。
- `ENTRY(kernel_start)` 只把 ELF header 的 entry 字段设为 `kernel_start` 的最终值；它不移动 symbol，也不生成 CPU 指令。

### 输入 D：没有修改 linker script 时，运行路径仍沿用第 13 课

- bootloader 在跳入载荷前已经输出 `HelloPTL`。
- bootloader 不看 ELF metadata，而是把 raw `kernel.bin` 固定读到 `0x10000`，再跳到 `0x10000`。
- `kernel.bin` 的前 16 字节仍是 `EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE`。
- 载荷两条跳转都是相对跳转；整段代码整体平移不会改变内部位移。
- `check-kernel-entry` 通过的条件是：完整输出为 `HelloPTLK`，且 monitor 看到 `RIP=0x1000e`、`CS=0x18 CS64`。

### 输入 E：本次 GNU ld/objcopy 管线的文件布局约定

- `kernel.elf` 的 ELF header 与对齐位于 `.text` 之前，当前 `.text` file offset 固定为 `0x1000`；file offset 不由 location counter 决定。
- 未修改时 `.text` VMA/LMA 由 linker script 设为 0；修正后应为 `0x10000`。
- `kernel.bin` 中 `.text` 从 file offset 0 开始。
- `os.img` 把 `kernel.bin` 放在 LBA 1，即 file offset `0x200`。
- BIOS 把它读到 guest physical `0x10000`；低 2 MiB 恒等映射使 linear address 也为 `0x10000`。

在 [学习记录](../notes/note-14.md) 中写出“输入 → 结论”的推导；已经填写的原始答案即使错误也不要删除。

1. 由输入 B/C 的 `base + offset`，推出尚未修改时 `kernel_start/kernel_magic/kernel_entry/kernel_hang` 的最终值。
2. 由 `ENTRY` 规则和第 1 题的 `kernel_start`，推出 ELF entry point；说明 `ENTRY` 是否会自动把 symbol 搬到 `0x10000`。
3. 由输入 A/B，推出 `kernel.bin` 的长度、前 16 字节，以及是否存在 64 KiB 前导零。
4. 由输入 D，逐步推出尚未修改时的完整 debug console、最终 `RIP/CS` 和 `check-kernel-entry` 结果；指出这里哪个环节完全绕过了错误的 ELF metadata。
5. 如果只把 location counter 改成 `0x10000`，由 `base + offset` 推出四个 symbol 和 ELF entry point。
6. 根据输入 E，填写同一条入口指令的五个位置：`kernel.elf` file offset、`.text` VMA/LMA、`kernel.bin` offset、`os.img` offset、guest physical/linear address。
7. 由输入 A/C/D，判断 `ENTRY(kernel_start)` 属于 ELF metadata 还是 CPU 指令，以及当前 bootloader 是否读取它。
8. 由输入 A 的产物类型与 ELF magic 规则，判断 `kernel.o/kernel.elf/kernel.bin/os.img` 各自的文件开头；再指出最终进入 guest RAM `0x10000` 的是哪一层字节。

## 1. 为什么 flat binary 不能承载下一阶段

到第 13 课为止，`nasm -f bin` 直接生成一串 raw bytes。它非常适合启动扇区和最小载荷：文件第一个字节就是第一条指令，没有 header，也没有需要解析的元数据。

但 C 编译器不会只交给我们一串“已经知道最终地址”的字节。随着工程扩大，会出现：

- 汇编入口与 C 代码位于不同 object file。
- `.text`、`.rodata`、`.data`、`.bss` 需要不同布局和权限。
- 一个文件引用另一个文件的函数或全局变量，地址尚未确定。
- 调试器需要 symbol 与 source line 信息。

assembler 只能知道单个输入文件内部的相对布局，不知道所有输入文件最终排在哪里。linker 的职责就是把多个 relocatable object 合并，解析 symbol reference、应用 relocation，并决定最终地址。

历史上，这种分工让大型程序能够分别编译：修改一个 C 文件不必重新汇编整个系统。对我们而言，它还有一个更直接的意义——后续 C 编译器会输出 ELF object，因此必须先建立 linker 这一层。

## 2. 三个产物分别是什么

### 2.1 `kernel.o`：地址还没定的 relocatable object

```sh
nasm -f elf64 -g -F dwarf -o build/kernel.o kernel/payload.asm
```

`-f elf64` 不再输出 flat binary，而是 ELF64 relocatable object。它包含：

- ELF header，类型是 `REL`。
- `.text` section 的 512 字节内容。
- symbol table：`kernel_start` 等符号目前是相对 `.text` 起点的 offset。
- DWARF debug sections，用于把机器地址关联回源码。

`SECTION .text` 告诉 NASM 后续字节属于名为 `.text` 的输入 section；`GLOBAL kernel_start` 让该 symbol 对 linker 可见。它们不生成 CPU 指令。

### 2.2 `kernel.elf`：地址已确定的 executable

```sh
x86_64-elf-ld -nostdlib -T kernel/linker.ld \
    -o build/kernel.elf build/kernel.o
```

`ld` 读取 object 和 linker script，输出类型为 `EXEC` 的 ELF64 文件。此时 `.text`、entry point 和 symbols 都有最终地址。

这里的 “executable” 不表示 macOS 可以直接运行它；它只表示 ELF 内部的链接工作已经完成。它面向 x86-64 bare metal，不是 Mach-O 宿主程序。

### 2.3 `kernel.bin`：只剩 section 内容的 raw bytes

```sh
x86_64-elf-objcopy -O binary build/kernel.elf build/kernel.bin
```

`objcopy -O binary` 移除 ELF header、program/section headers、symbol table 和 debug information，只输出 loadable section 的内容。当前只有一个 512 字节 `.text`，所以 `kernel.bin` 仍以：

```text
EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE
```

开头，长度仍为 512。

raw binary 的第一个字节对应最低 loadable address；当前只有一个 section，因此把 `.text` 的 VMA 从 0 改到 `0x10000` 不会在文件前制造 64 KiB 空洞。以后若存在相隔很远的多个 loadable sections，binary output 才可能用 gap fill 表示它们的间距。

## 3. linker script 逐行解释

linker script 不是汇编语言，也不由 CPU 执行：

```ld
ENTRY(kernel_start)

SECTIONS
{
    . = 0x00000000;

    .text :
    {
        *(.text)
    }
}
```

### `ENTRY(kernel_start)`

把 ELF header 的 `e_entry` 字段设置为 `kernel_start` 的最终 symbol value。它不移动 symbol、不生成 `JMP`，我们的 bootloader 也不会读取它。

### `SECTIONS { ... }`

描述 output sections 如何从 input sections 组成。

### `. = 0x00000000`

左侧的单独一个点是 location counter，不是 `.text` 的缩写。赋值表示“下一段输出从地址 0 开始”。这正是本课红灯：载荷实际被加载并执行在 `0x10000`，ELF metadata 却声称它位于 0。

### `.text : { *(.text) }`

- 左边 `.text` 是 output section 名称。
- `*(.text)` 中的 `*` 匹配所有 input files，括号里的 `.text` 匹配这些文件的同名 input section。
- 当前只有 `kernel.o`，所以它的 `.text` 被放入输出 `.text`。

location counter 为 0 时：

```text
kernel_start = 0x0000 + 0x00 = 0x0000
kernel_magic = 0x0000 + 0x02 = 0x0002
kernel_entry = 0x0000 + 0x0a = 0x000a
kernel_hang  = 0x0000 + 0x0e = 0x000e
```

把 location counter 改成 `0x10000` 后，同一组 offset 会整体平移。

## 4. 四个容易混淆的地址

绿灯后，同一条入口指令同时拥有多个坐标：

```text
build/kernel.elf file offset   0x1000   ELF header 与对齐之后
ELF .text VMA/LMA             0x10000  linker script 决定
build/kernel.bin file offset   0x0000   objcopy 已去掉 ELF metadata
build/os.img file offset       0x0200   LBA 1
guest physical/linear address  0x10000  BIOS 加载 + 恒等映射
```

它们数值不必相等，因为回答的是不同问题：

- file offset：字节在某个宿主文件的哪里。
- VMA（Virtual Memory Address）：section 运行时被代码和 symbol 视为什么地址。
- LMA（Load Memory Address）：section 应加载到哪里。本课 VMA=LMA。
- physical/linear address：CPU 运行时真实使用的 guest 地址；本课靠恒等映射相等。

linker script 只定义 ELF 的地址模型。我们的 BIOS loader 不解析 ELF program header，而是按固定协议把 raw `kernel.bin` 放到 `0x10000`；两边必须由我们人工保持一致。

## 5. 为什么红灯仍输出 `HelloPTLK`

红灯中 ELF symbols 从 0 开始，但 `objcopy` 得到的 raw bytes 与绿灯完全相同。bootloader 又无条件把这些 bytes 放在 `0x10000` 并跳到 `0x10000`。

当前载荷内部只有相对控制流：

```asm
jmp short kernel_entry
jmp kernel_hang
```

relative displacement 只取决于两个位置之间的距离。整段代码从链接地址 0 平移到实际地址 `0x10000`，距离没有变化，所以恰好仍能运行。

这不表示错误的 ELF metadata 无害。后续加入 C 后，代码会引用其他 symbol、全局数据或 relocation；linker 若按错误地址修补这些值，运行时就会访问错误位置。即使当前运行输出绿色，本课的新检查也必须保持红色。

这是一条重要的测试原则：

```text
运行结果正确 ≠ 所有构建不变量都正确
```

## 6. 红灯

在修改 linker script 前运行：

```sh
make inspect-kernel-elf
make check-kernel-elf
make check-debugcon
make check-kernel-entry
```

你应同时观察到：

```text
Entry point address: 0x0
0000000000000000 T kernel_start
000000000000000a T kernel_entry
.text VMA = 0x0
```

`make check-kernel-elf` 应失败并打印期望与实际 symbols；但后两项运行检查仍通过：

```text
debug console check passed: received 'HelloPTLK'
kernel-entry check passed: payload executing at 0x1000e under CS=0x18 (CS64)
```

这正是本课的单点红灯：执行行为没变，缺失的是 ELF 地址契约。

## 练习

只修改 `kernel/linker.ld` 中带 `RED / TODO` 的 location counter：

```ld
. = 0x00000000;
```

让 output `.text` 从载荷的真实加载地址 `0x10000` 开始。不要修改 `payload.asm`、bootloader、symbol offset 或测试脚本。

完成后运行：

```sh
make check-kernel-elf
make inspect-kernel-elf
make check-debugcon
make check-kernel-entry
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

1. `kernel.o` 与 `kernel.elf` 的 ELF type、entry point 分别是什么？为什么 object 还不能代表最终运行地址？
2. 红灯与绿灯的四个 symbol value 分别是什么？它们如何由 `.text` base 加 offset 得到？
3. linker script 中 location counter `.`、output `.text` 和 `*(.text)` 分别代表什么？
4. 绿灯时 `.text` 的 ELF file offset、VMA、LMA，及同一字节在 `kernel.bin`、`os.img` 和 guest RAM 中的位置分别是什么？
5. 为什么红灯 ELF 地址全错，`HelloPTLK` 与 `RIP=0x1000e` 却仍然正确？加入绝对 symbol reference 后可能发生什么？
6. `ENTRY(kernel_start)` 改变了什么？为什么它既没有生成跳转，也没有被当前 bootloader 使用？
7. `objcopy -O binary` 丢掉了哪些信息、保留了什么？为什么本课红绿两种 VMA 都产生 512 字节文件？
8. 这条 ELF 构建管线如何为后续 C 函数铺路？assembler、compiler 与 linker 将如何分工？

## 完成标准

- `make check-kernel-elf` 报告 ELF64 entry 与 `.text` VMA 都是 `0x10000`，raw payload 为 512 字节。
- `kernel_start=0x10000`、`kernel_magic=0x10002`、`kernel_entry=0x1000a`、`kernel_hang=0x1000e`。
- 能区分 relocatable object、linked ELF executable、raw binary 和 disk image。
- 能解释 file offset、VMA、LMA 与 guest physical address。
- 能解释为什么红灯运行仍绿色，以及这种“恰好位置无关”不能替代正确链接。
- 前 13 课全部回归通过。
