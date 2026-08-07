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
times 4 db 0               ; 生成四个 00
```

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

- [Intel SDM Volume 1: Basic Architecture](https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf)，Chapter 3
- [Intel SDM Volume 2: Instruction Set Reference](https://cdrdv2-public.intel.com/922478/325383-092-sdm-vol-2abcd.pdf)，查找 `OUT`

## 6. 当前阶段的查阅顺序

遇到不认识的东西时按下面顺序查：

1. 课程正文和本基础材料：获得适合当前上下文的解释。
2. NASM 文档：确认源代码语法、伪指令和输出格式。
3. Intel SDM Volume 2：确认 CPU 指令的操作数、行为、标志位和异常。
4. Intel SDM Volume 1/3：确认寄存器、运行模式、内存和系统编程机制。
