# 第 4 课：实模式分段与第一片栈

## 先修知识

开始前应理解：

- 第 1 课的实模式与 `CS:IP`。
- 第 2 课的 `org 0x7c00` 只影响汇编器地址计算。
- [NASM 与 x86 寄存器入门](reference/assembly-basics.md) 的第 1-4 节。

本课会先解释全部新增指令，再要求修改代码。

## 本课只建立一个不变量

不能依赖 BIOS 碰巧留下的 `DS`、`ES`、`SS` 和 `SP`。进入自己的启动代码后，应尽快建立已知的数据段与栈：

```text
DS = 0
ES = 0
SS = 0
SP = 0x7c00
```

## 1. 实模式地址如何形成

正常实模式下：

```text
linear address = segment × 16 + offset
```

因此同一地址可以有不同写法：

```text
0000:7c00 → 0x00000 + 0x7c00 = 0x7c00
07c0:0000 → 0x07c00 + 0x0000 = 0x7c00
```

第 1 课复位瞬间的隐藏 `CS.base=0xffff0000` 是特殊复位状态；执行远跳转重新加载 `CS` 后，才回到这里的普通规则。

常见段寄存器职责：

| 寄存器 | 当前阶段的用途 |
|---|---|
| `CS` | 指令所在代码段，配合 `IP` 取指 |
| `DS` | 大多数数据访问的默认段 |
| `ES` | 某些字符串指令的目标段 |
| `SS` | 栈段，配合 `SP` 定位栈顶 |

## 2. 为什么要主动设置段寄存器

`org 0x7c00` 让 NASM 按“代码位于 0x7c00”计算标签。如果以后执行：

```asm
mov al, [message]
```

CPU 默认使用 `DS:message`。只有我们明确知道 `DS`，才能知道最终访问哪个物理地址。汇编器的 `org` 不会修改 CPU 的 `DS`。

同理，`push`、`pop`、`call`、`ret` 和中断会使用 `SS:SP`。未初始化的栈可能覆盖代码、BIOS 数据或其他未知内存。

Intel 的寄存器与实模式定义见 [Intel SDM Volume 1](https://cdrdv2.intel.com/v1/dl/getContent/671436) Chapter 3，以及 [Intel SDM Volume 3A](https://cdrdv2.intel.com/v1/dl/getContent/671190) 的 real-address mode 章节。

## 3. 本课新增的 NASM/指令语法

段寄存器不能用这里想当然的立即数形式直接赋值：

```asm
; 不要写：mov ds, 0
```

先把零放进通用寄存器，再复制到段寄存器：

```asm
xor ax, ax       ; AX ← 0；相同操作数异或的结果为零
mov ds, ax       ; DS ← AX
mov es, ax       ; ES ← AX
```

`xor destination, source` 仍使用 NASM 的“目的在左、源在右”顺序。`xor ax, ax` 会修改算术标志位；本课后续代码不依赖这些旧标志。

设置栈的相似示例是：

```asm
cli              ; IF ← 0，暂时禁止可屏蔽硬件中断
xor ax, ax
mov ss, ax
mov sp, 0x7c00   ; 本课选择的栈顶
sti              ; IF ← 1，重新允许可屏蔽硬件中断
```

为什么保护 `SS:SP` 更新：如果中断恰好发生在栈段已经改变、栈顶尚未改变的中间状态，CPU 会使用不配套的 `SS:SP` 保存中断现场。

指令详情可在 [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110) 中查找 `CLI`、`STI`、`MOV`、`PUSH`。

## 4. 栈如何增长

在本课的 16 位栈中，执行 `push ax` 的效果可写成：

```text
SP ← SP - 2
memory16[SS × 16 + SP] ← AX
```

若初始 `SS=0`、`SP=0x7c00`、`AX=0x1234`，执行后：

```text
SP = 0x7bfe
memory[0x7bfe..0x7bff] = 34 12
```

栈从 `0x7c00` 向低地址增长，而启动扇区代码位于 `0x7c00..0x7dff`，所以第一次压栈不会覆盖当前代码。

## 5. 红灯与练习

当前 `start` 故意没有初始化段和栈。测试代码在固定地址执行：

```asm
mov ax, 0x1234
push ax
```

先运行：

```sh
make check-segments
```

记录失败时 GDB 观察到的 `DS/ES/SS/SP`。然后在 `boot/boot.asm` 的 TODO 位置建立以下状态：

```text
DS = ES = SS = 0
SP = 0x7c00
```

要求：

1. 用 `cli`/`sti` 保护栈切换。
2. 通过通用寄存器把零写入三个段寄存器。
3. 初始化代码不得超过 16 字节；固定检查点前的 `times` 会验证这一限制。

完成后再次运行：

```sh
make check-segments
make check-debugcon
make disassemble-boot
```

三个测试分别证明栈不变量、已有输出功能没有回归，以及产物中实际包含哪些指令。

## 观察题

1. 若 `DS=0x1000`、offset=`0x0200`，物理地址是多少？
2. 为什么 `org 0x7c00` 不能替代 `mov ds, ax`？
3. 为什么设置 `SP=0x7c00` 后，第一次 `push ax` 写入的是 `0x7bfe`？
4. `34 12` 与压入的 `0x1234` 有什么关系？
5. 如果 QEMU 的 BIOS 恰好已经令 `DS=0`，为什么我们仍应主动设置它？

## 完成标准

- 能从段值和偏移计算实模式线性地址。
- 能解释 `DS` 与 `org` 分别属于运行时和汇编时。
- GDB 证明 `DS=ES=SS=0`、`SP=0x7bfe`、栈顶 word 为 `0x1234`。
- debug console 的 `X` 仍然通过，说明没有引入回归。
