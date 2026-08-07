# 第 3 课：用 I/O 端口输出第一个字符

## 本课只引入一个机制

x86 除了内存地址空间，还有独立的 I/O 端口空间。`out` 指令把 CPU 寄存器中的值写给某个端口对应的设备。

我们使用 QEMU 的 `isa-debugcon` 设备。它模拟 Bochs 风格的 debug console，默认 I/O 基址是 `0xe9`，每次接收一个字节并把它转发到配置的字符后端。[QEMU `debugcon.c`](https://gitlab.com/qemu-project/qemu/-/blob/master/hw/char/debugcon.c)

这是 QEMU/Bochs 提供的调试设备，不应假设任意真实 PC 都有端口 `0xe9`。但 CPU 执行的 `out` 是真实的 x86 指令；未来串口驱动也会使用同一类端口 I/O 机制。

## 数据流

```text
ASCII 'X'
   ↓
AL 寄存器
   ↓  out 0xe9, al
I/O 端口 0xe9
   ↓
QEMU isa-debugcon
   ↓
宿主终端或日志文件
```

这里没有 BIOS `int` 调用，也没有操作 VGA 显存。我们的启动代码直接与一个模拟设备通信。

## 先修知识与最小语法

本课不假定你已经知道 NASM 或 x86 寄存器别名。先阅读 [NASM 与 x86 寄存器入门](reference/assembly-basics.md)，至少看完第 1、4、5 节。

### NASM 操作数顺序

NASM 使用 Intel 语法，常见二操作数形式是：

```text
instruction destination, source
```

因此：

```asm
mov al, value
```

表示把右侧的 `value` 复制到左侧的 `AL`，不是反过来。`'X'` 是字符常量，数值为十六进制 `0x58`。

### `AX` 和 `AL`

`AX` 是 16 位寄存器；`AL` 是它的低 8 位，`AH` 是它的高 8 位：

```text
AX = [ AH ][ AL ]
      15..8  7..0
```

把值写入 `AL` 只修改 `AX` 的低 8 位。它们是同一个物理寄存器的重叠视图，不是三个独立存储位置。

### `out` 的形式

本课使用：

```text
out immediate_port, al
```

它把 `AL` 的一个字节写到由 `immediate_port` 指定的 I/O 端口。这里的源是 `AL`，目的地是端口；这是 `out` 指令规定的专门语法。

权威参考：

- [NASM Language](https://www.nasm.us/doc/nasm03.html)
- [Intel SDM Volume 1](https://cdrdv2-public.intel.com/922477/253665-092-sdm-vol-1.pdf)，Chapter 3 的通用寄存器
- [Intel SDM Volume 2](https://cdrdv2-public.intel.com/922478/325383-092-sdm-vol-2abcd.pdf)，`OUT` 指令

## 先预测

在修改代码前，把以下预测写入 `notes/lesson-03.md`：

1. ASCII 字符 `X` 的数值是多少？
2. `out 0xe9, al` 的数据方向是端口到 CPU，还是 CPU 到端口？
3. 你预计“把字符放进 `AL`”和“写端口”各需要多少字节机器码？

## 红灯

当前启动扇区只会原地循环，不会写端口。运行：

```sh
make check-debugcon
```

测试应该报告期望 `X`、实际为空。把错误记录下来。

## 练习

修改 `boot/boot.asm` 的 `start`：

1. 把字符常量 `'X'` 放入 8 位寄存器 `AL`。
2. 用 `out imm8, al` 形式把它写到端口 `0xe9`。
3. 保留 `jmp $`，使 CPU 输出一次后稳定停留。

不要改测试期望，也不要使用 BIOS 中断。完成后运行：

```sh
make check-debugcon
```

测试会启动 QEMU、等待 debug console 收到数据、停止 QEMU，并要求输出严格等于一个 `X`。

## 反汇编证明

运行：

```sh
make disassemble-boot
```

找到对应 `mov`、`out`、`jmp` 的三行，记录每条指令的机器码和长度。反汇编是“产物里真的存在端口写指令”的构建证据；QEMU 输出则是“这条指令真的执行并到达设备”的运行证据。

也可以交互运行：

```sh
make run-debugcon
```

看到 `X` 后按 `Ctrl-C` 停止。QEMU 的字符后端负责把 debug console 连接到标准输入输出或文件。

## 观察题

1. `AL` 是 `AX` 的哪一部分？写入 `AL` 是否会替换整个 `AX`？
2. 为什么这里只能从测试结果证明“端口收到一个字节”，不能证明 VGA 屏幕显示了字符？
3. 如果把 `jmp $` 放到 `out` 前面，测试会发生什么？为什么？
4. 静态反汇编和运行输出分别证明了什么？

## 完成标准

- 先看到测试失败，再通过只增加两条有效指令使测试变绿。
- 能从反汇编识别 `mov al, imm8`、`out imm8, al` 和短跳转。
- 能说清 CPU、I/O 端口、QEMU 设备和宿主输出之间的数据方向。
