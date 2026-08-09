# 第 8 课：构造并加载第一张 GDT

## 先修知识

开始前应理解：

- 标签代表汇编器计算出的地址，方括号表示读取该地址中的内存。
- x86 多字节整数使用小端序。
- A20 已开启，但 CPU 仍在 16 位实模式。
- `db`、`dw`、`dd`、`dq` 分别生成 1、2、4、8 字节数据，参见 [NASM 与 x86 寄存器入门](reference/assembly-basics.md)。

本课会解释 GDT entry、descriptor、`LGDT` 和 GDTR，不会设置 `CR0.PE`，也不会切换保护模式。

硬件权威参考是 Intel SDM Volume 3A 的 “Protected-Mode Memory Management” 与 `LGDT` 指令说明；NASM 语法可查 [NASM Effective Addresses](https://www.nasm.us/doc/nasm03.html#section-3.3)。

## 本课只引入一个机制

在内存中构造一张最小 Global Descriptor Table，并让 CPU 的 GDTR 指向它。

```text
内存中的 GDT bytes
        │
        │ LGDT [gdt_descriptor]
        ▼
GDTR = { limit: 0x0017, base: 0x00007c50 }
```

`LGDT` 只装载 GDTR。它不会自动启用保护模式，也不会重新加载 `CS`、`DS` 等段寄存器。

## 1. 为什么需要 GDT

GDT 不是凭空设计出来的一张怪表。它是 x86 在保持旧软件兼容的前提下，从“扩大寻址范围”演化到“由 CPU 强制执行内存保护”留下的结构。

### 第一代：8086 的 segment 只是帮助 16 位 CPU 够到 1 MiB

1978 年的 8086 主要寄存器是 16 位，但外部地址总线有 20 位。如果只使用一个 16 位地址，最多只能表示 64 KiB。Intel 的办法是让程序提供两个 16 位量：segment 和 offset：

```text
segment 左移 4 位       offset
       0x12340     +     0x5678
                         │
                         ▼
物理地址 = 0x179b8
```

因此实模式中的段寄存器更像一个可移动的“64 KiB 窗口起点”：

```text
DS = 0x2000

物理内存
0x00000 ─────────────────────────────────────
0x20000 ┌──────── DS 当前窗口 ──────────────┐
        │ [DS:0000]                         │
        │ ...                               │ 64 KiB
0x2ffff └──────── [DS:ffff] ────────────────┘
```

这解决的是地址宽度问题，不是安全问题。程序可以把 `DS` 改成别的数值，把窗口移动到别人的代码、数据甚至操作系统区域；8086 不知道哪块内存“属于谁”，也没有 base/limit/读写权限可供检查。[Intel 1979 年的 8086 Family User's Manual](https://bitsavers.org/components/intel/8086/9800722-03_The_8086_Family_Users_Manual_Oct79.pdf) 将物理地址定义为 20 位值，并描述了 segment base 与 offset 的加法。

### 第二代：80286 想让多个程序可靠地共存

到 80286，目标不再只是“看见更多内存”，还包括运行多任务操作系统：

- 一个用户程序不能写内核内存。
- 一个程序不能越过分配给它的段。
- 数据段不能被当作代码执行。
- 不同代码需要不同特权级。

如果继续让程序直接把段寄存器当作 base，程序只要改写 `DS` 就能绕过这些规则。CPU 必须把“程序给出的编号”和“真正的地址及权限”分开。

问题是，一个完整段定义至少需要 base、limit、类型、读写/执行权限、特权级和 present 状态，显然装不进原来的 16 位段寄存器。80286 采取了一个兼容性很强的折中：

```text
可见的 16 位段寄存器                    内存中较大的记录
┌──────────────────┐                    ┌──────────────────────────┐
│ selector（编号） │ ──查表───────────▶ │ descriptor               │
└──────────────────┘                    │ base · limit · permissions│
                                        └──────────────────────────┘
```

旧指令编码仍然可以使用 16 位 `CS/DS/SS/ES`，但保护模式重新解释其中的值：它不再是 base 的高 16 位，而是 selector。selector 指向由操作系统建立、CPU 负责检查的 descriptor。

这就像从“任何人都能在地址栏直接填写仓库位置”，变成“程序只能提交门禁卡编号；CPU 去受控名册查出它能进入哪个区域、范围多大、允许读写还是执行”。类比只用于理解：硬件中的名册就是 descriptor table，门禁检查会在段寄存器加载和内存访问时产生真实异常。

### 为什么是一张表，而不是给每个段再造一堆寄存器

CPU 只有少量段寄存器，但操作系统可能管理许多代码段、数据段、任务和权限组合。把 descriptor 放在内存表中有三个直接好处：

1. 数量可扩展，不必为每个可能的段增加昂贵的硬件寄存器。
2. 操作系统可以在内存中创建和维护策略，程序只持有 selector。
3. CPU 可以在加载 selector 时检查表界限、类型、present 和特权级，再把常用字段缓存到段寄存器的隐藏部分；之后访问不必每次重新读表。

GDT 是全局表，所有任务都能引用；LDT 是可选的局部表。selector 中包含表索引、选择 GDT/LDT 的 TI 位以及请求特权级 RPL。Intel 的 80386 原始手册明确描述了 GDTR/LDTR 如何定位两张表、selector 如何索引 descriptor，以及 CPU 如何把 base、limit、type 等加载到段寄存器的不可见部分。[Intel 当前的分段说明](https://www.intel.com/content/www/us/en/developer/articles/technical/software-security-guidance/technical-documentation/speculative-behavior-swapgs-and-segment-registers.html) 仍沿用同一模型。

### 第三代：80386 把这个模型扩展到 32 位

80286 建立了 selector + descriptor table 的保护模式框架；80386 没有推倒重来，而是扩展 descriptor，使 base 可达 32 位，并加入 32 位默认操作数和 4 KiB 粒度等标志。于是可以建立我们本课使用的“平坦段”：base 为 0、有效范围接近 4 GiB。

所以本课的 `0x00cf9a000000ffff` 不是 8086 遗物，而是 80386 时代扩展后的 8 字节 descriptor 格式。现代 x86-64 为兼容这条演化链仍保留 GDT；长模式中大多数普通分段作用被弱化，页表承担主要地址空间隔离，但有效的代码段 descriptor、特权级和 TSS 等结构仍然需要 GDT。

### 那么 LGDT 又是为什么

GDT 只是普通内存中的一串字节。CPU 不会扫描内存猜测哪一串是表，因此还有一个专用寄存器 GDTR：

```text
GDTR.base  = GDT 从哪里开始
GDTR.limit = GDT 最后一个合法字节的偏移
```

启动时形成一条明确的因果链：

```text
bootloader 在内存中生成 descriptors
              │
              ▼
生成 { limit, base } 伪描述符
              │
              ▼
LGDT [gdt_descriptor] ──▶ GDTR 知道表在哪里
              │
              ▼
设置 CR0.PE + far jump ──▶ 保护模式才真正开始使用 selector
```

普通 `MOV` 不能写 GDTR，系统软件用 `LGDT` 从内存加载它。`LGDT` 只是在告诉 CPU“名册位于哪里、最长到哪里”，不是模式开关；真正进入保护模式还要设置 `CR0.PE`，并通过 far jump 重新加载 `CS`。我们故意把这两步拆成两课，以便分别取证。

[Intel 80386 Programmer's Reference Manual](https://read.seas.harvard.edu/~kohler/class/aosref/i386.pdf) 的 Memory Management 章节说明：处理器通过 GDTR/LDTR 定位 GDT/LDT，`LGDT` 负责访问 GDTR，selector 再选中表中的 descriptor。

### 回到本课的三项最小表

演化关系可以压缩为：

```text
8086：段寄存器是地址的一部分          → 能寻址，但不能保护
80286：段寄存器变成 selector           → descriptor 带来边界与权限检查
80386：扩展 descriptor 和地址宽度      → 可建立 0..4 GiB 平坦段
x86-64：主要隔离转向分页，但继承 GDT    → 启动、权限和 TSS 仍使用
```

本课程先建立三项最小 GDT：

本课程先建立三项最小 GDT：

```text
索引  selector  用途
0     0x00      null descriptor，必须保留
1     0x08      ring 0 的 32 位代码段
2     0x10      ring 0 的 32 位数据段
```

selector 的低 3 位另有用途，因此相邻表项的 selector 相差 8：`1 << 3 = 0x08`，`2 << 3 = 0x10`。本课只构造表；selector 会在下一课真正使用。

## 2. NASM 如何生成三项表

脚手架把 GDT 固定在 `0x7c50`：

```asm
gdt:
    dq 0x0000000000000000
    dq 0x00cf9a000000ffff
    dq 0x00cf92000000ffff
gdt_end:
```

`dq` 是 define quadword，直接生成 8 字节数据，不是 CPU 指令。三项表共 `3 × 8 = 24` 字节。

由于 x86 是小端序，两个非空项在内存中应为：

```text
代码项数值 0x00cf9a000000ffff → ff ff 00 00 00 9a cf 00
数据项数值 0x00cf92000000ffff → ff ff 00 00 00 92 cf 00
```

## 3. 先读懂两个非空 descriptor

每个 legacy segment descriptor 是 8 字节，字段不是按自然整数边界排列：

```text
字节 0..1   limit[15:0]      = 0xffff
字节 2..3   base[15:0]       = 0x0000
字节 4      base[23:16]      = 0x00
字节 5      access           = 0x9a 或 0x92
字节 6 低4位 limit[19:16]    = 0xf
字节 6 高4位 flags           = 0xc
字节 7      base[31:24]      = 0x00
```

共同的 `0xcf` 表示：

- limit 的高 4 位为 `0xf`，与低 16 位组合成 `0xfffff`。
- `G=1`，limit 以 4 KiB 为粒度，因此有效范围覆盖接近 4 GiB。
- `D/B=1`，这是 32 位代码/栈段。
- `L=0`，当前还不是 64 位代码段。

access byte：

```text
0x9a = 10011010b：present、ring 0、code、executable、readable
0x92 = 10010010b：present、ring 0、data、writable
```

这些常量不是要求死记；现阶段要能从原始字节指出 access byte 和 flags 在哪里。

## 4. GDTR 需要的伪描述符

`LGDT` 的内存操作数不是 GDT 第一项，而是一个包含“表长度和表地址”的结构：

```asm
gdt_descriptor:
    dw gdt_end - gdt - 1
    dd gdt
```

这里：

```text
gdt_end - gdt     = 24 = 0x18 字节
limit             = 24 - 1 = 23 = 0x17
base              = 0x00007c50
```

limit 使用“最后一个有效字节的偏移”，所以必须减一。这个 6 字节结构在内存中是：

```text
17 00 50 7c 00 00
│     └─────────┘
limit   base
```

## 5. `LGDT` 的方括号不能省略

正确形式：

```asm
lgdt [gdt_descriptor]
```

含义是：从 `gdt_descriptor` 指向的内存中读取 limit 和 base，再写入 GDTR。标签本身只是地址；`LGDT` 需要的是地址里的 6 字节结构，因此必须使用方括号。

在本课布局中，NASM 应生成：

```text
0f 01 16 68 7c    lgdt [0x7c68]
```

## 6. 红灯

当前 `main` 中放了五个 `NOP`，恰好占据未来 `LGDT` 的五个字节。GDT 数据已经存在，但 CPU 从未被告知它在哪里。

运行：

```sh
make inspect-gdt
make check-gdt
```

第一条命令应显示从文件偏移 `0x50` 开始的 30 字节：24 字节 GDT 加 6 字节伪描述符。第二条命令应失败：

```text
GDT check: expected GDTR base=0x00007c50 limit=0x0017 after boot code
GDT check: QEMU reported GDT=     00000000 00000000
```

测试先等待 `Hello`，确认启动代码已执行到最终循环，再查询 QEMU 的 GDTR，因此看到的是本次 boot code 执行后的状态。

## 7. 练习

把 `main` 中的五个红灯 `NOP` 替换为：

```asm
lgdt [gdt_descriptor]
```

不要修改 GDT 常量、固定地址或后面的 A20、字符串循环。

完成后运行：

```sh
make check-gdt
make check-a20
make check-debugcon
make check-call
make check-segments
make inspect-gdt
make disassemble-boot
```

## 观察题

1. 三项 GDT 共多少字节？为什么 GDTR.limit 是 `0x17` 而不是 `0x18`？
2. `gdt`、`gdt_end`、`gdt_descriptor` 分别是多少地址？
3. code descriptor 的 8 个内存字节是什么？其中 access byte 和 flags byte 分别是哪一个？
4. `0x9a` 与 `0x92` 的关键差异是什么？
5. 为什么 selector `0x08` 指向第 1 项，`0x10` 指向第 2 项？
6. `lgdt gdt_descriptor` 与 `lgdt [gdt_descriptor]` 在“地址”和“地址里的数据”上有什么区别？
7. 执行 `LGDT` 后，CPU 为什么仍在实模式？
8. 新增五字节后，第一次 `call putc` 压入的返回地址是多少？

## 完成标准

- `make check-gdt` 报告 GDTR base `0x00007c50`、limit `0x0017`。
- 能从 `inspect-gdt` 输出中划分三项 descriptor 和 6 字节伪描述符。
- 能解释 `size - 1`、小端序和 `LGDT` 方括号。
- 原有 A20、字符串、调用栈、段寄存器与启动扇区测试全部回归通过。
