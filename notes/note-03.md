# 第 3 课学习记录

日期：2026.08.08

## 实验前预测

1. `'X'` 的 ASCII 数值：88
2. `out` 的数据方向：小端？
3. 两条指令的预计长度：不知道

## 红灯

第一次运行 `make check-debugcon` 的错误：debug console: expected 'X', got ''

## 我的实现

```asm
; 只记录自己增加的两条指令

    MOV AL, 'X'
    OUT 0xE9, AL

```

## 原始观察

- `make check-debugcon`： debug console check passed: received 'X' from I/O port 0xe9
- `mov` 的机器码与长度：B058, 2 字节
- `out` 的机器码与长度：E6E9，2 字节
- `jmp` 的机器码与长度：EBFE， 2字节

## 我的解释

1. `AL` 与 `AX` 的关系：是一个寄存器，只是包含不同的范围，`AL` 是 `AX` 的低 8 位，即 bit 7..0
2. 测试实际证明了什么： 有输出回显，数据流从 AL 到了端口 0xE9
3. 如果先执行 `jmp $`： 那就是无限循环不会有输出
4. 静态证据与运行证据的区别：

	disassemble 是静态的，反汇编证明二进制中存在 out 指令；
	运行打印的 io 就是动态运行的,运行测试证明该指令被执行，且 QEMU debug console 收到 0x58；
	它不能证明 VGA 显示了字符。

## 仍然不清楚的问题

- 

