# 第 6 课：从内存遍历 NUL 结尾的字符串

## 先修知识

开始前应理解：

- `DS=0`，因此本课的数据地址可直接落在启动扇区所在的低内存。
- 第 5 课 `putc` 的接口：输入字符放在 `AL`，通过 `call putc` 输出。
- [NASM 与 x86 寄存器入门](reference/assembly-basics.md) 中的标签、立即数和方括号内存操作数。

本课会先解释 `SI`、`[si]`、`test`、`ZF`、`jz`、`inc`，再要求编写循环。

## 本课只引入一个机制

把一串连续字节视为字符串：从首地址开始，每次读取一个字节；遇到值 `0` 就结束，否则输出并移动到下一字节。

本课数据固定在 `0x7c40`：

```asm
message:
    db 'Hello', 0, 'Z'
```

对应字节：

```text
地址      值    含义
0x7c40   48    H
0x7c41   65    e
0x7c42   6c    l
0x7c43   6c    l
0x7c44   6f    o
0x7c45   00    NUL 终止符
0x7c46   5a    哨兵 Z，不应输出
```

`Z` 用来暴露越过终止符的错误。最终输出必须严格等于 `Hello`。

## 1. 标签地址与 `SI`

`SI` 是 16 位通用寄存器，名字来自 source index。普通 `mov` 中它仍可像其他通用寄存器一样保存数值。

```asm
mov si, message
```

右侧没有方括号，因此这里装入的是标签地址 `0x7c40`：

```text
SI ← 0x7c40
```

标签只在汇编时帮助 NASM 计算数值；运行时 CPU 看到的是编码进指令的立即数。

## 2. 方括号表示读取内存

```asm
mov al, [si]
```

表示从内存读取一个字节：

```text
AL ← memory8[DS × 16 + SI]
```

因为本课已经建立 `DS=0`，第一次读取的线性地址是：

```text
0 × 16 + 0x7c40 = 0x7c40
```

比较：

```asm
mov si, message   ; 装入地址
mov al, [si]      ; 读取该地址中的一个字节
```

NASM 内存操作数规则见 [NASM Effective Addresses](https://www.nasm.us/doc/nasm03.html#section-3.3)。

## 3. `test al, al` 与零标志

`test` 对两个操作数执行按位 AND，只更新标志位，不保存 AND 的结果：

```asm
test al, al
```

任意值与自身 AND 仍是自身，因此：

```text
AL = 0     → 结果为 0 → ZF = 1
AL != 0    → 结果非 0 → ZF = 0
```

`AL` 的内容不会被清零。

## 4. 条件跳转和指针前进

```asm
jz done       ; ZF=1 时跳转，否则继续下一条
inc si        ; SI ← SI + 1
jmp loop      ; 无条件回到循环开头
```

`jz` 的名字是 jump if zero；它读取先前指令留下的 `ZF`。因此 `test` 和 `jz` 之间不能随意插入会修改标志位的指令。

本课循环的伪代码是：

```text
SI = message
loop:
    AL = memory8[DS:SI]
    if AL == 0: goto done
    call putc
    SI = SI + 1
    goto loop
done:
    原地停留
```

`MOV`、`TEST`、`Jcc`、`INC` 的硬件行为可在 [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110) 中按指令名查询。

## 5. 红灯

当前代码仍只输出一个寄存器中的 `X`，但测试期望完整的 `Hello`：

```sh
make check-debugcon
```

记录 `expected 'Hello', got 'X'`。再查看实际数据：

```sh
make inspect-message
```

它应显示偏移 `0x40` 的七个字节：

```text
48 65 6c 6c 6f 00 5a
```

## 6. 练习

重写 `main` 到 `hang` 之间的代码，实现上述伪代码。必须使用：

- `SI` 保存当前位置。
- `[si]` 读取一个字符。
- `test al, al` 与 `jz hang` 检查终止符。
- `call putc` 输出非零字符。
- `inc si` 和无条件 `jmp` 形成循环。

保持：

- `main` 位于 `0x7c10`。
- `putc` 位于 `0x7c30`。
- `message` 位于 `0x7c40`。

固定地址前的 `times` 会在代码过长时让汇编失败，而不是悄悄移动测试目标。

完成后运行：

```sh
make check-debugcon
make check-call
make check-segments
make inspect-message
make disassemble-boot
```

## 观察题

1. `mov si, message` 和 `mov al, [si]` 分别得到地址还是数据？
2. 为什么 `test al, al` 不会改变 `AL`？
3. 为什么必须先判断 NUL，再调用 `putc`？
4. 当 `SI=0x7c45` 时，`ZF` 是多少，`jz` 是否跳转？
5. 哨兵 `Z` 对测试有什么价值？
6. 为什么 `call putc` 后仍能继续使用 `SI`？这是硬件保证还是我们的函数约定？

## 完成标准

- 输出严格等于 `Hello`，不会包含 NUL 后的 `Z`。
- 能区分标签地址、寄存器中的地址和地址里的数据。
- 能解释 `TEST → ZF → JZ` 的控制依赖。
- call/ret、段寄存器与启动扇区测试全部回归通过。

