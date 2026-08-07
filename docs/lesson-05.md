# 第 5 课：`call`、返回地址与 `ret`

## 先修知识

开始前应理解：

- 第 4 课建立的 `SS=0, SP=0x7c00` 栈不变量。
- [NASM 与 x86 寄存器入门](reference/assembly-basics.md) 的标签与 Intel 操作数顺序。

本课新增的 `call`、`ret` 和相对位移会在练习前完整说明。

## 本课只引入一个机制

把字符输出代码放进名为 `putc` 的子程序，由 `call` 进入，再由 `ret` 返回。重点不是代码复用，而是证明控制流怎样借助栈记住返回位置。

## 1. 标签不是运行时对象

NASM 标签表示当前位置的地址：

```asm
putc:
    out 0xe9, al
    ret
```

标签本身不生成机器码。`call putc` 中的 `putc` 会在汇编时被解析为目标地址。

## 2. 16 位近 `call` 做了什么

本课使用同一代码段内的 near call。可以把它理解为两个不可分割的步骤：

```text
SP ← SP - 2
memory16[SS × 16 + SP] ← 下一条指令的 IP
IP ← putc
```

注意栈上保存的是 call 后面那条指令的地址，不是 `putc` 的地址，也不是 call 自己的地址。

NASM 源码写作：

```asm
call putc
```

在当前布局中：

```text
call 位于       0x7c12
call 长度       3 字节
返回 IP         0x7c15
putc 位于       0x7c20
初始 SP         0x7c00
进入 putc 的 SP 0x7bfe
```

机器码中的目标通常不是完整地址，而是相对于 call 后一条指令的有符号位移：

```text
displacement = 0x7c20 - 0x7c15 = 0x000b
```

因此你应在反汇编中看到类似：

```text
E8 0B 00    call 0x7c20
```

## 3. `ret` 做了什么

near `ret` 执行相反过程：

```text
IP ← memory16[SS × 16 + SP]
SP ← SP + 2
```

所以正确配对后：

```text
SP: 0x7c00 → 0x7bfe → 0x7c00
IP: call → putc → 0x7c15
```

`call`/`ret` 的规范行为见 [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110) 的 `CALL` 与 `RET` 条目。

## 4. 函数接口由我们约定

硬件不会自动知道 `putc` 的参数。我们人为约定：

```text
输入：AL = 要输出的一个字节
输出：端口 0xe9 收到该字节
返回：通过栈顶返回地址回到调用者
```

当前 `putc` 只读取 `AL`，不会主动保存其他寄存器。以后需要明确哪些寄存器由调用者保存、哪些由被调用者保存，这会逐步发展为 ABI。

## 5. 红灯

初始代码仍直接执行：

```asm
out 0xe9, al
nop
```

这两条指令恰好占 3 字节，与将要写的 near `call` 一样长。因此固定地址不会改变。

先运行：

```sh
make check-debugcon
make check-call
```

第一个测试应通过，因为确实输出了 `X`；第二个应失败，因为控制流在进入 `putc` 前就到达 `hang`。这说明“结果相同”不能证明“实现机制正确”。

## 6. 练习

在 `boot/boot.asm` 中，把 TODO 下方的这三字节：

```asm
out 0xe9, al
nop
```

替换为一条：

```asm
call putc
```

不要改变 `putc`、`hang` 或对齐填充。然后运行：

```sh
make check-call
make check-segments
make check-debugcon
make disassemble-boot
```

新测试会在 `putc` 入口验证：

- `SP=0x7bfe`。
- 栈顶 word 是返回地址 `0x7c15`。
- `ret` 后重新到达 `0x7c15`。
- `SP` 恢复为 `0x7c00`。
- debug console 仍只收到一个 `X`。

## 观察题

1. 为什么保存的是 `0x7c15`，不是 `0x7c12` 或 `0x7c20`？
2. `E8 0B 00` 中的 `0x000b` 是怎样计算出来的？
3. 如果 `putc` 删除 `ret`，CPU 会继续执行什么字节？为什么？
4. 为什么仅看到 `X` 不能证明程序使用了函数调用？
5. `call` 前后 `SP` 的变化与第 4 课的 `push` 有什么共同点？

## 完成标准

- 能逐步描述 near `call` 和 near `ret` 对 `IP`、`SP`、内存的影响。
- GDB 证明栈顶返回地址和 `SP` 往返过程。
- 能从反汇编解释 call 的相对位移。
- 所有回归测试通过。

