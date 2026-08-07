# 第 4 课学习记录

日期：

## 实验前计算

1. `1000:0200` 的物理地址： 0x10200
2. `SS=0, SP=0x7c00` 时执行一次 16 位 `push`，新 `SP`： 0x7bfe
3. 压入 `0x1234` 后的两个内存字节：0x34,0x12

## 红灯

- 初始 `DS`：0x0
- 初始 `ES`：0x0
- 初始 `SS`：0x0
- 执行探针 `push` 后的 `SP`：0x6f0a
- 测试失败原因：没有主动设置 SP，未得到预期的 0x7bfe

## 我的实现

```asm
; 记录初始化段寄存器与栈的代码

    cli
    xor ax, ax
    mov es, ax
    mov ds, ax
    mov ss, ax
    mov sp, 0x7c00
    sti

```

## 绿灯原始观察

- `DS/ES/SS`： 0x0/0x0/0x0
- `SP`： 0x7bfe
- 栈线性地址： 0x7bfe
- 栈顶 word： 0x1234
- `make check-debugcon`： debug console check passed: received 'X' from I/O port 0xe9

## 我的解释

1. `org` 为什么不能代替初始化 `DS`： org 只是给 nasm 说明启动位置
2. 栈为什么向低地址移动： x86 PUSH 的定义：先令 SP = SP - 2，再写入 word。
3. `34 12` 与 `0x1234` 的关系： 只是 端序的问题,小端序把低字节 0x34 放在低地址，把高字节 0x12 放在下一地址。
4. 为什么不依赖 BIOS 碰巧留下的寄存器值：因为不可靠 CPU 默认使用 `DS:message`。只有我们明确知道 `DS`，才能知道最终访问哪个物理地址。汇编器的 `org` 不会修改 CPU 的 `DS`。
同理，`push`、`pop`、`call`、`ret` 和中断会使用 `SS:SP`。未初始化的栈可能覆盖代码、BIOS 数据或其他未知内存。

## 仍然不清楚的问题

- 
