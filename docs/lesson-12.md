# 第 12 课：用 BIOS 把第 2 个扇区读入内存

## 先修知识

开始前应理解：

- BIOS 只把启动设备的第一个 512 字节扇区加载到物理地址 `0x7c00`。
- 实模式地址按 `segment × 16 + offset` 计算。
- `AH`、`AL` 是 `AX` 的高、低 8 位；修改 `DH` 不会修改 `DL`。
- `CALL/RET` 使用栈保存返回地址；函数可以用 `PUSH/POP` 保存调用者的寄存器。
- 当前启动代码能建立低 2 MiB 恒等映射，并最终以 `CS64` 执行。

本课第一次使用 BIOS 磁盘服务、raw disk image 和 `INT`/`JC`。所需语法已补到 [NASM 与 x86 寄存器入门](reference/assembly-basics.md#9-intjc-与-bios-寄存器接口)，不要求你在练习时另外猜语法。

参考资料：

- [SeaBIOS 的 INT 13h 磁盘服务实现](https://github.com/coreboot/seabios/blob/master/src/disk.c)：QEMU PC 默认固件所实现接口的源码。
- [Ralf Brown's Interrupt List：INT 13/AH=02h](https://www.ctyme.com/intr/rb-0607.htm)：IBM PC 兼容 BIOS 接口的事实标准索引。
- [QEMU system invocation：disk images](https://www.qemu.org/docs/master/system/invocation.html)：`-drive` 与 raw image 的运行方式。

## 本课只引入一个机制

让仍处于实模式的 bootloader 调用 BIOS `INT 13h, AH=02h`，把启动镜像的第 2 个扇区读到物理地址 `0x10000`。

本课只负责“读入”，不会跳转到载荷，也不会引入 linker script、ELF、C 语言或 x86-64 ABI。绿灯后原有输出仍是 `HelloPTL`；下一课才把执行权交给独立载荷。

```text
磁盘镜像文件                         物理内存

offset 0x000 / LBA 0 ─┐           0x07c00 ┌──────────────┐
  boot.bin（512 B）    └─ BIOS ──▶         │ boot sector  │
                                           └──────────────┘

offset 0x200 / LBA 1 ─┐ INT 13h   0x10000 ┌──────────────┐
  kernel.bin（512 B）  └─────────▶         │  KERNEL64... │
                                           └──────────────┘
```

## 1. 为什么已经有 `kernel.bin`，RAM 中却仍是零

`kernel/payload.asm` 被 NASM 组装成 512 字节的 `build/kernel.bin`。构建系统再生成一个 1.44 MiB raw floppy image：

```text
文件偏移       LBA       内容
0x000          0         build/boot.bin
0x200          1         build/kernel.bin
0x400..末尾    2..2879   零
```

这里有三层容易混淆：

1. `kernel/payload.asm` 是源代码。
2. `build/kernel.bin` 和 `build/os.img` 是宿主机文件系统里的字节。
3. 物理地址 `0x10000` 是 guest RAM，只有运行时真的进行磁盘读取后才会出现那些字节。

NASM 中的：

```asm
org 0x00010000
```

只告诉汇编器“计算标签和跳转时，假设这些字节将位于 `0x10000`”。它不会生成加载动作，也不会把文件复制到 RAM。这与 `boot.asm` 中的 `org 0x7c00` 完全相同：真正加载启动扇区的是 BIOS，不是 `ORG`。

因此红灯可以同时满足：

```text
镜像 offset 0x200：EB 08 4B 45 52 4E 45 4C ...  ← 文件中存在
guest RAM 0x10000：00 00 00 00 00 00 00 00 ...  ← 尚未加载
```

## 2. 为什么 BIOS 默认只加载第 1 个扇区

传统 PC BIOS 的启动职责很小：选择启动设备，把它的 boot sector 搬到 `0x7c00`，检查末尾签名 `55 aa`，然后跳进去执行。BIOS 不知道我们的第 2 个扇区是内核、图片还是垃圾数据，也不知道应该放到哪个 RAM 地址。

512 字节限制因此不是“整个操作系统只能有 512 字节”，而是第一阶段 bootloader 的天然边界。第一阶段必须主动读取更多扇区，或者加载一个更强的第二阶段 loader。

这也是历史上的常见启动链：

```text
BIOS
  └─只认识 boot sector
       └─小型 stage 1 loader
            └─读取 stage 2 / kernel
                 └─操作系统接管机器
```

我们此刻的 512 字节 boot sector 就是 stage 1；第 2 个扇区是第一次独立于它的载荷。

## 3. `INT 13h` 到底是什么

`INT imm8` 是 CPU 指令。它根据中断向量号转移控制流；在 BIOS 建立的实模式环境中，向量 `0x13` 指向固件的磁盘服务入口。

```asm
int 0x13
```

这句话应拆成两层理解：

- **CPU 层**：执行软件中断指令，保存返回现场并按照向量表进入处理程序。
- **固件约定层**：BIOS 规定 `INT 13h` 是磁盘服务，并用 `AH` 选择具体功能、用其他寄存器传参数。

所以 `INT 13h` 不是“磁盘控制器的一条指令”，也不是磁盘硬件突然发来的 IRQ。它更像 bootloader 调用 BIOS 提供的一个函数，只是调用约定建立在寄存器和软件中断上。

BIOS 服务是一套固件 ABI：调用者必须在执行 `INT` 前填好约定的寄存器，BIOS 返回时通过 flags 和寄存器报告结果。

## 4. `AH=02h` 的完整寄存器契约

`INT 13h` 有许多子功能；本课使用经典 CHS read：

```text
输入
AH = 0x02       功能号：read sectors
AL = 0x01       读取 1 个扇区
CH = 0x00       cylinder 的低 8 位
CL = 0x02       sector 2（低 6 位；sector 从 1 开始）
DH = 0x00       head 0
DL = BIOS 给我们的启动驱动器号
ES:BX           目标缓冲区

输出
CF = 0          成功
CF = 1          失败，此时 AH 是错误状态码
```

在更大的 CHS 地址中，cylinder 的高 2 位还会放在 `CL` 的 bit 6..7。本课读取 cylinder 0，所以这两位均为零。

### `DL` 从哪里来

BIOS 跳到 boot sector 时，会把启动驱动器号留在 `DL`：传统 floppy 通常是 `0x00`，第一块 hard disk 通常是 `0x80`。bootloader 不应凭空把它改写成某个常量；同一份代码可能从不同设备启动。

当前 `start` 在调用 `load_kernel` 前没有修改 `DX`，因此 `DL` 仍携带 BIOS 输入。函数内部可以设置 `DH=0` 选择 head 0，因为 `DH` 和 `DL` 是 `DX` 中互不重叠的两个字节。

### 为什么要检查 CF

`CF` 是 carry flag。对这个 BIOS 服务而言，它是返回协议的一部分：

```asm
int 0x13
jc disk_read_failed
```

`JC` 的含义是 jump if carry，即 `CF=1` 时跳转。不能只调用 `INT 13h` 然后假定成功，否则读盘失败后 CPU 会继续执行一块未初始化的 RAM。

本课失败路径向 debug console 持续输出 `E`。因此若寄存器填错，测试不会把“超时”误当成毫无线索的故障。

## 5. 从 LBA 1 到 CHS 0/0/2

raw image 本质上只是连续字节。构建工具通常按从零开始的 LBA（Logical Block Address）描述扇区：

```text
LBA 0 = 第 1 个扇区 = 文件偏移 0 × 512 = 0x000
LBA 1 = 第 2 个扇区 = 文件偏移 1 × 512 = 0x200
```

经典 BIOS `AH=02h` 使用 CHS（Cylinder/Head/Sector），其中 sector 编号从 **1** 开始。对于 1.44 MiB floppy，常用 geometry 是每 track 18 sectors、2 heads；换算公式是：

```text
LBA = ((cylinder × heads_per_cylinder + head)
       × sectors_per_track)
      + (sector - 1)
```

代入 `C=0, H=0, S=2`：

```text
LBA = ((0 × 2 + 0) × 18) + (2 - 1) = 1
```

因此下面三个说法指向同一批 512 字节：

```text
镜像文件偏移 0x200
= LBA 1
= BIOS CHS cylinder 0 / head 0 / sector 2
```

最常见的 off-by-one 错误，是误把 `CL=1` 当作 LBA 1；实际上 `CL=1` 会再次读取 boot sector。

## 6. 为什么目标是 `ES:BX = 0x1000:0x0000`

实模式下 BIOS 用 `ES:BX` 接收目标缓冲区：

```text
physical = ES × 16 + BX
         = 0x1000 × 16 + 0x0000
         = 0x10000
```

选 `0x10000` 有几个具体原因：

- 不覆盖 `0x1000..0x3fff` 的 PML4、PDPT 和 PD。
- 不覆盖 `0x7c00..0x7dff` 的 boot sector。
- 不碰保护模式后使用的 `0x90000` 栈。
- 位于已建立的低 2 MiB 恒等映射中；进入 long mode 后，线性地址 `0x10000` 仍翻译到物理地址 `0x10000`。
- 实模式 BIOS 可以直接用 `ES:BX` 表示。

本课只读一个扇区，因此缓冲区范围是 `0x10000..0x101ff`。以后载荷变大时，还必须检查读取范围不会跨越保留区域、DMA 限制或 `ES:BX` 的 64 KiB 边界。

## 7. 为什么必须在切换保护模式之前读盘

BIOS 磁盘接口是固件为传统实模式调用者提供的环境。它通常依赖实模式中断向量表、16 位代码和 BIOS 自己的内部状态。

进入保护模式后：

- `INT 0x13` 会根据当前 `IDTR` 和保护模式 IDT 规则找 gate，而不是按实模式 IVT 规则直接找 BIOS 入口。
- 段寄存器已经是 selector，不再按 `segment × 16` 解释。
- 进入 long mode 后更不能假定固件代码可按 64 位规则执行。

理论上可以构造复杂的模式切回跳板，但这既脆弱又超出本课目标。正常内核在接管机器后会使用自己的磁盘驱动；在接管前，stage 1 趁实模式固件服务仍可用，把后续代码先读到 RAM。

因此本课的调用顺序是：

```text
初始化实模式段和栈
        ↓
CALL load_kernel ── INT 13h
        ↓
开启 A20、加载 GDT
        ↓
保护模式 → 分页 → long mode
```

## 8. 为什么函数要保存寄存器

`load_kernel` 会把 BIOS 参数放入 `AX/BX/CX/DX/ES`。但旧课已经建立了一个不变量：到 `main` 时 `ES=0`、`SP=0x7c00`，而后续代码也不应意外继承 BIOS 的临时返回值。

函数入口因此先保存：

```asm
push ax
push bx
push cx
push dx
push es
```

成功后逆序恢复：

```asm
pop es
pop dx
pop cx
pop bx
pop ax
ret
```

栈是后进先出，所以恢复顺序必须与保存顺序相反。`PUSH ES`/`POP ES` 是合法的 16 位段寄存器保存方式。最终 `RET` 再弹出最早由 `CALL` 压入的返回 IP，于是 `SP` 回到 `0x7c00`。

## 9. 如何证明读到的不是“恰好非零”

载荷前 16 字节被刻意设计成：

```text
EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE
      └──────── K E R N E L 6 4 ────────┘
```

开头 `EB 08` 会在未来执行载荷时跳过 8 字节 `KERNEL64` 标记。当前只观察，不执行。

QEMU monitor 的 `xp /2gx 0x10000` 按两个 64 位 little-endian 数显示同一批字节：

```text
00010000: 0x4c454e52454b08eb 0xfeebe9e64bb03436
```

第一个数的最低有效字节是 `EB`，所以它位于最低地址 `0x10000`；随后依次是 `08 4B 45...`。测试比较完整的两个 qword，而不只是检查“这块 RAM 不为零”，从而能发现读错扇区、读错地址或内容损坏。

## 10. 红灯机制（先不要运行）

当前 `load_kernel` 直接返回，没有设置 BIOS 读盘寄存器，也没有执行 `INT 13h`。因此第 2 个扇区虽然已经存在于磁盘镜像，guest 物理地址 `0x10000` 仍不会得到这批字节。

`HelloPTL` 仍可能正常出现，因为旧控制流可以继续进入 `CS64`；这只能证明启动链走完，不能证明额外扇区已从磁盘搬到 RAM。这里先理解红灯的因果，不运行命令，也不查看物理内存结果。

## 实验前预测

在修改代码前，把以下答案写入 `notes/note-12.md`，错误预测也不要删除：

1. `ES=0x1000, BX=0` 对应的物理地址是多少？载荷最后一个字节落在哪个地址？
2. 镜像文件偏移 `0x200`、LBA 1、CHS 0/0/2 为什么指向同一个扇区？
3. 调用 `INT 13h, AH=02h` 前，`AX/BX/CX/DX/ES` 的关键字节分别应是什么？
4. `DL` 的值由谁提供？为什么不能在 bootloader 中直接假定它总是 `0x00`？
5. `CF=0` 和 `CF=1` 分别代表什么？本课应使用哪个条件跳转检查失败？
6. 第 2 个扇区前 16 个字节是什么？按 little-endian 显示成两个 qword 后是什么？
7. 为什么读盘发生在设置 `CR0.PE` 之前，而不是进入 long mode 后？
8. 为什么仍然看到 `HelloPTL` 不能证明第 2 个扇区已经被读入？

## 运行真实红灯

完成预测后运行：

```sh
make inspect-image
make disassemble-kernel
make check-kernel-load
```

前两条会证明第 2 个扇区确实存在于镜像。第三条应报告：期望在物理地址 `0x10000` 看到载荷，但当前仍是零。把实际错误输出原样记录到笔记中。

## 练习

打开 `boot/boot.asm`，只修改 `load_kernel` 中带 `RED`/`TODO` 的直接返回占位：

1. 把 `ES:BX` 设置为 `0x1000:0x0000`。
2. 按第 4 节的寄存器契约选择 `AH=02h`，读取 cylinder 0、head 0、sector 2 的一个扇区。
3. 保留 BIOS 传入的 `DL`。
4. 执行 `INT 0x13`，若 carry flag 为 1，跳到现有 `.disk_read_failed`。
5. 成功路径应自然落到 `.done`，不要改固定地址、载荷内容和旧课代码。

可以用以下命令查看自己写出的 16 位机器码：

```sh
make disassemble-boot
```

完成后运行：

```sh
make check-kernel-load
make check-debugcon
make check-segments
make check-call
make check-a20
make check-gdt
make check-protected
make check-page-tables
make check-long-mode
```

## 观察题

1. `make inspect-image` 如何证明 boot sector 与载荷在同一镜像中的边界？
2. 绿灯时 `0x10000` 的两个 qword 是什么？把第一个 qword 还原为内存字节时，为什么 `EB` 在最低地址？
3. `load_kernel` 的反汇编中，`INT 13h` 和 `JC` 的机器码各是什么？`JC` 的目标地址是什么？
4. 为什么 `mov dh, 0` 不会破坏 BIOS 传入的启动驱动器号？
5. 保存并恢复 `ES` 对 `main` 入口的不变量有什么作用？保存五个 16 位寄存器加上 `CALL` 返回地址时，栈最多向下移动多少字节？
6. 如果误写 `CL=1`，会读到什么？测试看到的第一个 qword 大概率会变成什么类型的内容？
7. `ORG 0x10000`、把 payload 写入镜像 offset `0x200`、运行时读到 RAM `0x10000`，三者分别由谁完成？
8. 为什么本课不直接跳到 `0x10000`？把“读盘正确”和“转移执行正确”拆成两课带来了什么可验证性？

## 完成标准

- `make check-image` 报告 1.44 MiB、boot sector 位于 LBA 0、payload 位于 LBA 1。
- `make check-kernel-load` 报告 sector 2 已出现在物理地址 `0x10000`，两个 qword 完全匹配。
- 能解释 file offset、LBA、CHS sector number 与 guest physical address 是四种不同概念。
- 能逐项说明 `INT 13h AH=02h` 的输入寄存器、`DL` 的来源和 `CF` 的返回语义。
- 原有实模式寄存器、调用栈、A20、GDT、保护模式、页表和 long mode 测试全部回归通过。
