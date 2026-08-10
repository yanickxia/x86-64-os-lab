# NASM 与 x86 寄存器入门

这份材料只覆盖前几课立即需要的内容，不要求一次背完。第一次遇到新语法时，课程正文仍会再次解释。

## 1. NASM 一行代码的结构

```text
label:    instruction    operands    ; comment
```

四部分都可能省略。例如：

```asm
start:                  ; 只定义标签
    mov al, 'A'         ; 指令：把字符常量放入寄存器
    jmp start           ; 指令：跳到标签 start
```

NASM 使用 Intel 语法，二操作数指令通常写成：

```text
instruction destination, source
```

所以 `mov al, 'A'` 表示从右向左复制：`AL ← 'A'`。寄存器名不加 `%`，立即数不加 `$`。

权威参考：[NASM 3.1 - Layout of a Source Line](https://www.nasm.us/doc/nasm03.html#section-3.1)。

## 2. 指令、汇编指示与伪指令

需要区分三类东西：

- CPU 指令会生成将来由 CPU 执行的机器码，如 `mov`、`out`、`jmp`。
- 汇编指示影响 NASM 如何编码，如 `bits 16`、`org 0x7c00`；CPU 不会执行它们。
- 伪指令直接生成或重复数据，如 `db`、`dw`、`times`；它们也不是运行时指令。

示例：

```asm
bits 16                    ; 按 16 位规则编码
org 0x7c00                 ; 假设本二进制加载在 0x7c00

value: db 0x41             ; 生成一个字节 41
word:  dw 0x1234           ; 生成两个字节 34 12
dword: dd 0x12345678       ; 生成四个字节 78 56 34 12
qword: dq 0x0102030405060708 ; 生成八个字节 08 07 06 05 04 03 02 01
times 4 db 0               ; 生成四个 00
```

`db`、`dw`、`dd`、`dq` 分别定义 1、2、4、8 字节数据。x86 使用小端序，所以多字节整数的最低有效字节先出现在较低地址；例如 `dw 0x1234` 在内存中是 `34 12`。

参考：

- [NASM 3.2 - Pseudo-Instructions](https://www.nasm.us/doc/nasm03.html#section-3.2)
- [NASM 3.2.5 - TIMES](https://www.nasm.us/doc/nasm03.html#section-3.2.5)
- [NASM 9.1 - Flat Binary Output](https://www.nasm.us/doc/nasm09.html#section-9.1)

## 3. 数值、字符和地址表达式

```asm
mov al, 88       ; 十进制
mov al, 0x58     ; 十六进制，数值仍是 88
mov al, 'X'      ; 字符常量，数值仍是 0x58
```

几个常用符号：

- `$`：当前位置。
- `$$`：当前 section 的起点；平坦二进制中可理解为本文件这一段的起点。
- `$ - $$`：当前位置相对本段起点的字节数。
- `[address]`：访问该地址中的内存内容；没有方括号通常表示数值或地址本身。

例如：

```asm
times 510 - ($ - $$) db 0
```

表示用零重复填充，直到已经生成 510 字节。

权威参考：[NASM 3.4 - Constants](https://www.nasm.us/doc/nasm03.html#section-3.4)。

## 4. `RAX`、`EAX`、`AX`、`AH`、`AL` 的关系

它们不是五个相互独立的寄存器，而是同一个通用寄存器的重叠视图：

```text
63                                                        0
+----------------------------------------------------------+
|                         RAX                              | 64 bit
+----------------------------------+-----------------------+
                                   |          EAX          | 32 bit
                                   +-----------+-----------+
                                               |    AX     | 16 bit
                                               +-----+-----+
                                               | AH  | AL  | 各 8 bit
                                               +-----+-----+
                                                15  8 7   0
```

- `AL` 是 `AX` 的低 8 位，即 bit 7..0。
- `AH` 是 `AX` 的高 8 位，即 bit 15..8。
- `AX` 是 `EAX` 的低 16 位；`EAX` 是 `RAX` 的低 32 位。
- `mov al, 'X'` 只替换 bit 7..0，不会修改 `AH`。
- 将来进入 64 位模式后要特别注意：写入 `EAX` 会把 `RAX` 的高 32 位清零。这是 x86-64 的专门规则。

本课程当前处于 16 位实模式，因此首先使用 `AX`、`AH`、`AL`。Intel 对这些通用寄存器的定义见 Volume 1 的 “Basic Execution Environment”。

## 5. 为什么 `out` 使用 `AL`

`out` 把累加器中的值写入 I/O 端口：

```asm
out 0xe9, al      ; 向端口 0xe9 写 1 字节
```

数据方向是：

```text
AL → I/O port 0xe9
```

`out` 的不同编码可使用 `AL`、`AX` 或 `EAX`，分别写 1、2 或 4 字节。第 3 课的 debug console 一次接收一个字节，所以使用 `AL`。

硬件与指令参考：

- [Intel SDM Volume 1: Basic Architecture](https://cdrdv2.intel.com/v1/dl/getContent/671436)，Chapter 3
- [Intel SDM Volume 2: Instruction Set Reference](https://cdrdv2.intel.com/v1/dl/getContent/671110)，查找 `OUT`

## 6. 当前阶段的查阅顺序

遇到不认识的东西时按下面顺序查：

1. 课程正文和本基础材料：获得适合当前上下文的解释。
2. NASM 文档：确认源代码语法、伪指令和输出格式。
3. Intel SDM Volume 2：确认 CPU 指令的操作数、行为、标志位和异常。
4. Intel SDM Volume 1/3：确认寄存器、运行模式、内存和系统编程机制。

## 7. 内存操作数宽度与 `REP STOSD`

`EQU` 可以为数值定义汇编期常量：

```asm
PAGE_SIZE equ 4096
TABLE_ADDR equ 0x1000
```

它不会生成机器码，也不会分配内存。NASM 只在遇到 `PAGE_SIZE` 或 `TABLE_ADDR` 时以对应数值替换。因此“`TABLE_ADDR equ 0x1000`”不会让 `0x1000` 处自动出现一张表；代码仍必须在运行时初始化那段 RAM。

当内存操作数的宽度无法从另一个寄存器操作数推断时，NASM 需要显式宽度：

```asm
mov byte  [0x1000], 0x41        ; 写 1 字节
mov word  [0x1000], 0x1234      ; 写 2 字节
mov dword [0x1000], 0x12345678  ; 写 4 字节
```

`STOSD` 把 `EAX` 的 4 字节存入 `ES:EDI`。`REP` 前缀让 CPU 重复执行 `ECX` 次；每次后 `ECX` 减 1，`EDI` 根据 direction flag 增加或减少 4：

```asm
cld             ; DF=0，后续 EDI 向高地址增长
xor eax, eax    ; 要写入的 dword 是 0
mov edi, 0x1000
mov ecx, 1024
rep stosd       ; 清零 1024 × 4 = 4096 字节
```

`REP` 是 instruction prefix；`STOSD` 是 CPU 指令。它们都会生成机器码，不同于 `bits` 这样只影响汇编器的指示。

参考：

- [NASM Effective Addresses](https://www.nasm.us/doc/nasm03.html#section-3.3)
- [NASM `REP` Prefixes](https://www.nasm.us/doc/nasm04.html#section-4.2)
- Intel SDM Volume 2：`CLD` 与 `STOS`

## 8. 汇编期位掩码、控制寄存器与 MSR

NASM 表达式可以在汇编期计算位掩码：

```asm
FEATURE_BIT equ 1 << 5   ; 汇编器计算为 0x20，不生成移位指令
```

控制寄存器不能直接接收 immediate，通常先通过通用寄存器做读—改—写：

```asm
mov eax, cr4
or eax, FEATURE_BIT
mov cr4, eax
```

`CR0/CR3/CR4` 属于体系结构控制寄存器；MSR 则通过编号访问。`RDMSR/WRMSR` 的固定接口是：

```text
ECX      = MSR number
EDX:EAX  = 64-bit value
```

例如保留一个 MSR 的其他位、只设置低 32 位中的某个 feature：

```asm
mov ecx, 0xc0000080
rdmsr
or eax, 1 << 8
wrmsr
```

这些都是特权指令；操作系统内核可以使用，普通用户程序不能随意执行。`bits 64` 与之前的 `bits 16/32` 一样，只控制 NASM 的编码假设；真正的 CPU 模式由控制寄存器、MSR 和 `CS` descriptor 决定。

参考：

- [NASM Expressions](https://www.nasm.us/doc/nasm03.html#section-3.5)
- [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110)：`MOV—Control Registers`、`RDMSR`、`WRMSR`

## 9. `INT`、`JC` 与 BIOS 寄存器接口

`INT imm8` 是带一个 8 位向量号的 CPU 指令：

```asm
int 0x13
```

在 PC BIOS 建立的实模式环境中，向量 `0x13` 对应固件磁盘服务。`AH` 选择子功能，其余寄存器传参；这是 BIOS 规定的调用约定，不是 NASM 自己赋予寄存器的含义。

例如 `AH=0x02` 的经典 sector read 接口使用 `AL` 表示扇区数、`CH/CL/DH` 表示 CHS 地址、`DL` 表示驱动器、`ES:BX` 表示目标缓冲区。固件通过 carry flag 返回成功或失败。

`JC label` 是 jump if carry：

```asm
int 0x13
jc disk_error      ; 仅当 CF=1 时跳转
```

与之对应，`JNC` 是 jump if not carry，即 `CF=0` 时跳转。`JC`/`JNC` 读取现有 flags，不会自行执行比较。对于 BIOS 接口，必须根据该服务文档解释 flag，不能把 `CF` 永远理解成普通加法的进位。

段寄存器也可在 16 位代码中用栈临时保存：

```asm
push es
mov ax, 0x1000
mov es, ax
; 使用 ES:BX 作为 BIOS 缓冲区
pop es
```

x86 不允许 `mov es, 0x1000` 这种 immediate 直接写段寄存器，所以先把数值放入通用寄存器 `AX`。栈按后进先出工作；多个 `PUSH` 必须按相反顺序 `POP`。

要区分两个方向相反的事件：

- 软件执行 `INT 0x13`，主动调用固件服务。
- 硬件 IRQ 由设备异步发出，请求 CPU 处理中断。

它们都可能使用 CPU 的中断机制，但“调用 BIOS 读盘”并不等于“磁盘硬件此刻向 CPU 发出 IRQ 13”。

参考：

- [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110)：`INT n/INTO/INT3`、`JC/JNC/Jcc`
- [SeaBIOS disk services](https://github.com/coreboot/seabios/blob/master/src/disk.c)
- [Ralf Brown's Interrupt List：INT 13/AH=02h](https://www.ctyme.com/intr/rb-0607.htm)

## 10. ELF `SECTION`、`GLOBAL` 与链接

`nasm -f bin` 直接输出 raw bytes；`nasm -f elf64` 则输出带 section、symbol 和 relocation 信息的 ELF relocatable object。ELF 源码通常显式声明 section：

```asm
bits 64
section .text
global entry

entry:
    nop
```

- `SECTION .text` 把后续生成的内容放入名为 `.text` 的 input section。
- `GLOBAL entry` 把局部标签导出为 linker 可见的全局 symbol。
- `BITS 64` 仍只控制指令编码。
- 这些都是 NASM 指示，不是 CPU 指令。

ELF object 中的 symbol 通常先表示“相对某个 section 的位置”。linker 收集各个 input sections、决定 output section 的地址，再把 symbol 与 relocation 修补为最终值。

flat binary 使用 `ORG` 为当前字节流提供地址假设；ELF 构建通常不在每个源文件里用 `ORG` 决定最终地址，而由统一的 linker script 布局。这样汇编与 C object 才能分别编译后再组合。

参考：

- [NASM ELF64 Output Format](https://www.nasm.us/doc/nasm10.html)
- [GNU ld：Linker Scripts](https://sourceware.org/binutils/docs/ld/Scripts.html)
- [System V ABI：ELF](https://refspecs.linuxfoundation.org/elf/gabi4+/contents.html)
