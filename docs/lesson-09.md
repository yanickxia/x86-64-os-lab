# 第 9 课：设置 CR0.PE，真正进入 32 位保护模式

## 先修知识

开始前应理解：

- A20 已开启，可以访问 1 MiB 以上的物理地址。
- GDTR 已指向 `0x7c50` 的三项 GDT。
- selector `0x08` 指向 32 位代码 descriptor，`0x10` 指向数据 descriptor。
- GDT、GDTR 与 `LGDT` 各自的职责。

本课会解释 `CR0.PE`、控制寄存器读—改—写、far jump、段寄存器的隐藏状态，以及 NASM 的 `bits 16` / `bits 32`。

硬件参考：[Intel 64 and IA-32 Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)，重点是 Volume 3A 的 “Protected-Mode Memory Management” 和 “Mode Switching”。

## 本课只引入一个机制

让 CPU 从 16 位实模式切换到 32 位保护模式，并用寄存器状态证明切换成功：

```text
CR0.PE = 1
CS = 0x0008  → GDT 第 1 项，32 位代码段
DS = SS = 0x0010 → GDT 第 2 项，32 位数据段
```

本课仍然不是 64 位模式。x86-64 启动必须经过保护模式，之后才能建立页表、设置 EFER.LME 并进入 long mode。

## 1. 为什么切换不是一条“进入保护模式”指令

80286 首次引入 x86 protected mode；当时系统软件通过 machine status word 的 PE 位和 `LMSW` 操作它。80386 将该状态扩展为今天熟悉的 `CR0`，并允许用 `MOV` 读写控制寄存器；PE 仍是 bit 0。

但 CPU 的模式不是只有一个布尔值。至少有两类状态必须衔接：

```text
全局模式状态                 当前代码段状态
CR0.PE                       CS selector
                              CS 隐藏缓存中的 base/limit/access/D 位
```

如果只把 `CR0.PE` 设成 1，CPU 知道“保护规则已经启用”，但当前 `CS` 还没有通过新 GDT 重新加载。它的可见值和隐藏缓存仍来自此前的实模式执行环境。

因此切换天然分成两步：

```text
1. 设置 CR0.PE              启用保护模式语义
2. far jump 到 0x08:入口    用 GDT code descriptor 重新装载 CS
```

这不是多余仪式，而是在“启用新解释规则”后，立即为当前指令流选择一项合法的代码 descriptor。

## 2. 为什么必须先 CLI

当前启动代码在实模式初始化后执行过 `STI`，但我们还没有建立保护模式 IDT。如果在切换窗口收到可屏蔽中断，CPU 会按保护模式规则解释中断入口，而相应的 IDT 和处理函数尚不存在，结果通常是连续异常并最终 triple fault/reset。

因此进入切换序列前先执行：

```asm
cli
```

它只屏蔽普通可屏蔽中断；NMI 另有规则。课程会在建立 IDT 后才重新开启中断。

## 3. 安全修改 CR0.PE

红灯时 QEMU 报告：

```text
CR0 = 0x00000010
```

我们只想把 bit 0 设为 1，不能覆盖 CR0 中其他已有位：

```asm
mov eax, cr0
or eax, 0x01
mov cr0, eax
```

结果：

```text
原值  00000010
OR    00000001
      ────────
新值  00000011
```

`MOV` 控制寄存器是 CPU 指令，不是普通内存读写。当前源码处于 `bits 16`，但控制寄存器接口使用 `EAX`；`or eax, 1` 的机器码包含 `0x66` operand-size override，告诉 CPU 这条算术指令操作 32 位 EAX。

## 4. 为什么必须 far jump

near jump 只改变当前代码段内的 `IP/EIP`，不会重新加载 `CS`。我们需要的 far jump 同时携带：

```text
selector = 0x0008
offset   = 0x7c90
```

NASM：

```asm
jmp 0x08:protected_mode_entry
```

### selector 为什么是 `0x08` 和 `0x10`

selector 不是 descriptor 的内存地址，而是一个 16 位编码：

```text
15                         3  2   1       0
+---------------------------+----+---------+
|         index             | TI |   RPL   |
+---------------------------+----+---------+
```

- `index`：bits 15..3，指定表中的第几项。每项 descriptor 恰好是 8 字节，所以编码时相当于左移 3 位。
- `TI`：bit 2，`0` 选 GDT，`1` 选 LDT。本课只用 GDT。
- `RPL`：bits 1..0，Requested Privilege Level。本课在 ring 0，因此是 `0`。

因此：

```text
selector = (index << 3) | (TI << 2) | RPL

code descriptor：index=1, TI=0, RPL=0
    (1 << 3) | (0 << 2) | 0 = 0x08

data descriptor：index=2, TI=0, RPL=0
    (2 << 3) | (0 << 2) | 0 = 0x10
```

所以“GDT 第 2 项”中的 `2` 是 index，写入段寄存器的 selector 则是 `0x10`。

本课布局中的机器码是：

```text
ea 90 7c 08 00
   └───┘ └───┘
   offset selector
```

x86 是小端序，所以 `0x7c90` 存为 `90 7c`，`0x0008` 存为 `08 00`。

执行 far jump 时，CPU：

1. 把 `0x08 >> 3 = 1` 作为 GDT 索引。
2. 读取 code descriptor，检查 present、类型和权限。
3. 把 selector 写入 CS 的可见部分。
4. 把 base、limit、access 和 `D=1` 等字段写入 CS 的隐藏部分。
5. 从 descriptor base + `0x7c90` 继续取指。

code descriptor 的 `D=1` 使后续默认操作数和地址宽度成为 32 位。这也是为什么 far jump 之后的源码必须按 `bits 32` 编码。

## 5. `bits 32` 不是模式切换指令

```asm
bits 16
enter_protected_mode:
    ; 这里由 CPU 按 16 位默认规则解码

bits 32
protected_mode_entry:
    ; 这里由 CPU 按 32 位默认规则解码
```

`bits 16` 和 `bits 32` 只告诉 NASM应该生成哪种默认编码，它们不会产生任何机器码，也不能改变 CPU 模式。

真正改变 CPU 状态的是：

```text
MOV CR0（PE=1） + far jump（加载 D=1 的 CS descriptor）
```

如果源码写了 `bits 32`，但 CPU 仍按 16 位解码，同一串机器码会被错误解释；反过来也一样。汇编器假设必须与运行时 CPU 状态吻合。

## 6. 为什么进入后还要重载 DS、ES、SS

far jump 只重新加载 `CS`，不会自动改变数据段和栈段。保护模式入口已经由脚手架提供：

```asm
bits 32
protected_mode_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov esp, 0x00090000

    mov al, 'P'
    out 0xe9, al
```

`0x10 >> 3 = 2`，对应 GDT 的 data descriptor。加载 `DS/ES/SS` 时，CPU 同样检查 descriptor 并填充各段寄存器的隐藏缓存。

新栈使用 `SS:ESP = 0x10:0x00090000`。因为 data descriptor base 为 0，线性栈顶就是 `0x00090000`。栈仍向低地址增长。

## 7. 为什么切换代码搬到了 0x7c70

上一课结束时，`main` 与固定地址 `putc=0x7c30` 之间只剩两个字节：

```text
0x7c10  main
   ...  A20、LGDT、字符串循环
0x7c2c  原来的两字节 jmp hang
0x7c30  putc（旧课测试固定）
```

完整切换序列需要 16 字节：

```text
fa                         cli
0f 20 c0                   mov eax, cr0
66 83 c8 01                or eax, 1
0f 22 c0                   mov cr0, eax
ea 90 7c 08 00             jmp 0x08:0x7c90
```

如果直接塞进 `main`，NASM 的固定地址填充会因空间不足而报错；如果移动 `putc/message/GDT`，又会同时破坏多门旧课的 GDB 和原始字节证据。

因此脚手架保留全部旧地址，只把原来 `0x7c2c` 的两字节死循环改成一个 short jump：

```asm
hang:
    jmp enter_protected_mode   ; 0x7c2c → 0x7c70
```

新的区域布局是：

```text
0x7c70  16 位模式切换代码
0x7c90  32 位 protected_mode_entry
```

`times 0x70 - ($ - $$)` 和 `times 0x90 - ($ - $$)` 把两个入口固定住。这个布局不是 x86 硬件要求，而是课程为了保持旧课证据可重复所做的工程选择。

## 8. 红灯为什么也输出 HelloP

红灯代码在 `0x7c70` 故意不修改 CR0，只在实模式输出字符 `P` 后停住：

```asm
mov al, 'P'
out 0xe9, al
.real_mode_hang:
    jmp .real_mode_hang
```

所以红灯与绿灯表面输出完全相同：

```text
HelloP
```

但寄存器证据不同：

```text
              红灯                    绿灯
CR0           0x00000010              0x00000011
CS            0x0000                  0x0008
DS / SS       0x0000                  0x0010
执行位置       real_mode_hang          protected_mode_hang
```

这刻意说明：I/O 输出只是程序行为，不足以证明 CPU 模式。模式结论必须来自 `CR0`、段 selector 和 descriptor 状态。

运行红灯：

```sh
make check-protected
make inspect-protected
```

`check-protected` 应失败并打印 `CR0=0x10`、`CS=DS=SS=0`；`inspect-protected` 会显示 `0x7c70` 后的原始代码字节。

## 9. 练习

把 `enter_protected_mode` 中输出 `P` 并原地循环的红灯代码替换为：

```asm
cli
mov eax, cr0
or eax, 0x01
mov cr0, eax
jmp 0x08:protected_mode_entry
```

保持：

- 不修改 GDT 和 `protected_mode_entry`。
- far jump 使用 code selector `0x08`。
- 数据段使用 selector `0x10`。
- 最终 debug console 输出严格等于 `HelloP`。

完成后运行：

```sh
make check-protected
make check-gdt
make check-a20
make check-debugcon
make check-call
make check-segments
make inspect-protected
make disassemble-boot
```

`make disassemble-boot` 会按 CPU 的解码模式分成三段：

- `0x7c00-0x7c32`：16 位启动与实模式主路径。
- `0x7c70-0x7c81`：16 位的 CR0 修改和 far jump。
- `0x7c90-0x7ca4`：far jump 后按 32 位解码的保护模式入口。

不要把整个启动扇区固定按 16 位解码：`bits 16` 和 `bits 32` 不会写入机器码，`ndisasm` 无法自动知道 far jump 之后 CPU 改用了 32 位解码。字符串、GDT 和填充区域是数据，也不应伪装成指令输出。

## 观察题

1. PE 与 far jump 分别改变了 CPU 的哪一部分状态？
2. 为什么使用读—改—写，而不是直接 `mov eax, 1`？
3. 为什么切换前必须执行 `CLI`？
4. 为什么 near jump 不能代替 far jump？
5. far jump 如何使用 selector `0x08`？它的 index、TI 和 RPL 各是多少？
6. `bits 32` 与真正的 CPU 模式切换有什么区别？
7. far jump 后为什么还要重新加载 `DS/ES/SS`？
8. 为什么要重新设置 `ESP`？当 data descriptor base 为 0 时，新栈顶的线性地址是多少？
9. 进入保护模式后，`CS=0x08` 的可见部分和隐藏部分分别保存什么？
10. 为什么本课进入的是 32 位保护模式，而不是直接进入 64 位 long mode？

## 完成标准

- `make check-protected` 报告 `CR0.PE=1, CS=0x0008, DS=SS=0x0010`。
- 能解释 PE 与 far jump 各自改变哪一部分 CPU 状态。
- 能说明 `bits 32` 只是编码指示。
- 能解释为什么相同输出不能证明 CPU 模式。
- GDT、A20、字符串、调用栈、段寄存器与启动扇区测试全部回归通过。
