# 第 10 课：构造低 2 MiB 恒等映射

## 先修知识

开始前应能用上一课的证据说明：

- CPU 已处于 32 位保护模式，`CR0.PE=1`。
- `CS=0x08` 选中 32 位 code descriptor。
- `DS=ES=SS=0x10`，这些 descriptor 的 base 都是 0。
- `ESP=0x00090000`，当前代码位于 `0x00007c00` 附近。

本课会首次使用 `EDI`、`ECX`、`CLD`、`REP STOSD` 和 `mov dword [absolute_address], immediate`。这些语法在练习前都会解释，不需要预先会写。

硬件参考：[Intel 64 and IA-32 Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)，重点是 Volume 3A 的“4-Level Paging”、“Paging-Structure Entries”和“2-MByte Pages”。

## 本课只引入一个机制

在物理内存中构造一条有效的页表链，把低 2 MiB 线性地址恒等映射到同数值的物理地址：

```text
PML4[0] → PDPT[0] → PD[0, PS=1] → 2 MiB physical page at 0
```

本课不加载 `CR3`，不设置 `CR4.PAE`，不设置 `EFER.LME`，也不打开 `CR0.PG`。页表完成后仍然只是内存中的数据结构；下一课才让 CPU 真正走这条翻译路径。

## 1. 分页从哪里来

8086 最初使用分段来扩大地址范围；80286 把段改造成带 base、limit 和权限的 descriptor，从而提供保护。但“每个程序看到一套独立、可以稀疏分配的地址空间”用大小不一的段很难管理：

- 段长度不同，物理内存容易形成外部碎片。
- 增长一个段可能要搬动它。
- 以段为单位换入换出过于粗糙。
- 很难便宜地表示“中间大片不存在，两端各有一小块”的稀疏空间。

80386 加入了 paging，它把分段得到的线性地址再切成固定大小的 page，并通过页表映射到物理 page frame：

```text
逻辑地址 --segmentation--> 线性地址 --paging--> 物理地址
```

我们当前的段 base 都是 0，所以逻辑 offset 和线性地址数值相同。开启分页后，线性地址才会再翻译一次。在 x86-64 long mode 中，paging 不再是可选项；要进 long mode，必须先准备好它。

## 2. 为什么不是一张巨大的平面表

若对 48 位虚拟地址空间中的每个 4 KiB page 都预留一个 8 字节 entry，单个地址空间的平面表就需要：

```text
2^48 / 2^12 × 8 = 2^39 bytes = 512 GiB
```

这对大多数只用少量地址的程序极其浪费。多级页表把映射做成一棵基数树：只为真正使用的分支分配下一级表。

常见的 48 位四级分页把线性地址拆成：

```text
63           48 47        39 38        30 29        21 20        12 11       0
+---------------+------------+------------+------------+------------+----------+
| canonical sign| PML4 index | PDPT index |  PD index  |  PT index  |  offset  |
+---------------+------------+------------+------------+------------+----------+
                    9 bits       9 bits       9 bits       9 bits      12 bits
```

每个 index 都是 9 位，因此每张表有 `2^9 = 512` 个 entry。每个 entry 是 8 字节，整张表恰好是 `512 × 8 = 4096` 字节，也就是一个 4 KiB page。

不要靠目测拆地址，可以直接按位计算：

```text
PML4 index = (linear_address >> 39) & 0x1ff
PDPT index = (linear_address >> 30) & 0x1ff
PD index   = (linear_address >> 21) & 0x1ff
PT index   = (linear_address >> 12) & 0x1ff
4 KiB offset = linear_address & 0xfff
```

`0x1ff` 的二进制是 9 个 1，用来保留移位后的低 9 位。如果 PD entry 使用 `PS=1` 的 2 MiB page，遍历不再读 PT，最后 21 位整体成为 large-page offset：

```text
2 MiB offset = linear_address & 0x1fffff
```

## 3. 本课为什么只需要三张表

完整的 4 KiB 映射路径是：

```text
PML4 → PDPT → PD → PT → 4 KiB page
```

但 x86-64 允许在 page-directory entry 中把 `PS`（Page Size，bit 7）设为 1。此时 PD entry 直接映射一个 2 MiB page，页表遍历在 PD 提前结束：

```text
PML4 → PDPT → PD[PS=1] → 2 MiB page
```

这仍使用 long mode 的四级分页格式，只是大页 leaf 省掉了最后一张 PT。对启动阶段很合适：我们只需要保证当前代码 `0x7c00` 和栈 `0x90000` 在开分页的瞬间仍然可访问，它们都位于低 2 MiB。

## 4. 恒等映射为什么能让切换平滑

恒等映射表示：

```text
linear address X → physical address X
```

假设 CPU 在 `0x7cac` 附近执行时打开分页。如果页表将线性地址 `0x7cac` 仍映射到物理地址 `0x7cac`，那么下一次取指仍然会读到同一串机器码。栈地址 `0x90000` 也同理。

如果开分页后当前指令或栈没有映射，CPU 会立即产生 page fault。我们又还没有 IDT 和 page-fault handler，最终往往表现为 triple fault 和复位。所以低地址恒等映射是进入 long mode 时的过渡桥梁。

## 5. PML4 是从哪里来的

硬件不会替 bootloader 创建一个叫“PML4”的对象，BIOS 也不会把它传给我们。此时 QEMU 提供的 RAM 已经存在；是我们的 bootloader 主动选了三个物理页，并通过清零和写 entry 赋予它们“页表”这个含义。

源码现在用 `EQU` 明确命名这些地址：

```text
PML4_ADDR = 0x1000  覆盖 0x1000..0x1fff
PDPT_ADDR = 0x2000  覆盖 0x2000..0x2fff
PD_ADDR   = 0x3000  覆盖 0x3000..0x3fff
```

`EQU` 只在汇编时定义数值常量，不会分配 RAM，也不会向 `boot.bin` 写入字节：

```asm
PML4_ADDR equ 0x00001000
```

真正使物理页 `0x1000..0x3fff` 成为可用页表的是 `setup_page_tables` 的运行时内存写入：它先从 `PML4_ADDR` 开始清零 12 KiB，再写入三个 entry。

下面三个概念不能混在一起：

```text
PML4 所在的物理页：  0x1000
PML4[0] 这个 entry 的地址：0x1000 + 0 × 8 = 0x1000
PML4[0] 指向的下级表：  0x2000 处的 PDPT
```

内存布局与下一课的 CR3 关系是：

```text
                    下一课
CR3  --------------------------------------+
                                           v
physical 0x1000  +-----------------------------+
                 | PML4[0] = 0x2000 | flags    |----+
                 | PML4[1] = 0                  |    |
                 | ...                          |    |
physical 0x1fff  +-----------------------------+    |
                                                    v
physical 0x2000  +-----------------------------+
                 | PDPT[0] = 0x3000 | flags    |----+
                 | ...                          |    |
physical 0x2fff  +-----------------------------+    |
                                                    v
physical 0x3000  +-----------------------------+
                 | PD[0] = base 0 | PS | flags |----> low 2 MiB
                 | ...                          |
physical 0x3fff  +-----------------------------+
```

本课尚未写 CR3，所以虽然这些内存已按页表格式布置，CPU 还不知道要从 `0x1000` 开始遍历。

为什么不在 `boot.bin` 里直接定义三张表？因为三张表共需 12 KiB，而 BIOS 本课只会加载 512 字节启动扇区。因此代码必须在启动后去初始化另一段 RAM。

对齐不是为了整齐。page-table entry 的低位要存放 flags，下一级表的物理地址使用高位。因为 4 KiB 对齐地址的低 12 位本来就是 0，硬件才能把这些位复用为 `P/RW/US/...` 等属性。

数值 `address` 是否 4 KiB 对齐可以用下式检查：

```text
address & 0x0fff == 0
```

这三页位于常规低端 RAM，避开了启动扇区 `0x7c00`、栈顶 `0x90000` 和 1 MiB 以上区域。真正内核将来会从物理内存管理器申请页表；现在先用固定地址保持实验可重复。

## 6. 页表 entry 中的地址与 flags

页表 entry 是 64 位数值。本课只用四个概念：

- `P`，bit 0：Present。为 1 才能沿该 entry 继续遍历。
- `RW`，bit 1：允许写。
- `US`，bit 2：是否允许 ring 3 使用。本课保持 0，只允许 supervisor。
- `PS`，PD entry 的 bit 7：为 1 表示这是 2 MiB leaf，不再指向 PT。

因此两个“指向下一级表”的 entry 都使用 flags：

```text
P | RW = 0x001 | 0x002 = 0x003
```

链路中的三个值应该表示：

```text
PML4[0]  next table at 0x2000, P=1, RW=1
PDPT[0]  next table at 0x3000, P=1, RW=1
PD[0]    2 MiB physical base 0, P=1, RW=1, PS=1
```

先不要只把测试期待的十六进制数当成魔法常量；先分别用“地址部分 OR flags”把它们算出来。

## 7. 为什么先清零 12 KiB

一个 entry 的 `P=0` 表示该分支不存在。新分配的物理内存不应被假定为零；若未主动初始化，随机低位可能把本不存在的 entry 变成 present。

脚手架已提供：

```asm
cld
xor eax, eax
mov edi, 0x00001000
mov ecx, 0x00000c00
rep stosd
```

其状态变化是：

```text
EAX = 0
EDI = 0x1000
ECX = 0x0c00 = 3072
DF  = 0

REP STOSD: 重复 ECX 次，每次把 EAX 的 4 字节写到 ES:EDI，然后 EDI += 4
3072 × 4 = 12288 bytes = 3 × 4096 bytes
```

`CLD` 把 direction flag 清零，保证 `EDI` 向高地址增长。`ES` 已在保护模式入口加载了 base=0 的 data descriptor，因此第一次写入的线性地址就是 `0x1000`。

## 8. 32 位代码如何写 64 位 entry

我们当前仍执行 32 位代码。NASM 需要通过 `dword` 知道写入宽度：

```asm
mov dword [0x4000], 0x12345003
```

数据方向是：

```text
32-bit immediate → memory at absolute address
```

每个页表 entry 其实是 8 字节，但本课的所有表和映射地址都低于 4 GiB，所以 entry 的高 32 位应为 0。清零循环已经把它们置零；练习只需要写每个 entry 的低 32 位。

练习中可以直接使用 `PML4_ADDR`、`PDPT_ADDR` 和 `PD_ADDR` 这些常量，避免把“表在哪里”隐藏在裸的十六进制数中。

本布局中 `mov dword [absolute], immediate` 每条恰好编码为 10 字节。红灯为三条指令预留了 30 个 NOP，因此替换后 `RET` 的地址不变。

NASM 权威参考：[NASM Effective Addresses](https://www.nasm.us/doc/nasm03.html#section-3.3) 与 [NASM `REP` Prefixes](https://www.nasm.us/doc/nasm04.html#section-4.2)。CPU 指令语义见 Intel SDM Volume 2 的 `CLD`、`MOV` 和 `STOS`。

## 9. 如何证明表真的在物理内存中

红灯和绿灯都会输出：

```text
HelloPT
```

`T` 只能证明 `setup_page_tables` 返回了，不能证明 entry 正确。`make check-page-tables` 使用 QEMU monitor 的 `xp`（examine physical memory）直接读取：

```text
physical 0x1000  PML4[0]
physical 0x2000  PDPT[0]
physical 0x3000  PD[0]
```

这里刻意使用物理内存观察，因为 paging 尚未开启，CPU 还没有通过这些 entry 进行地址翻译。

## 实验前计算

修改代码前，把以下结果写入 `notes/note-10.md`：

1. `0x00007c00` 在四级 4 KiB 地址拆分中的 PML4、PDPT、PD、PT index 和 page offset。
2. `0x00090000` 的四个 index 和 page offset。
3. 为什么这两个地址在 2 MiB large page 下会命中同一个 PD entry。
4. `P | RW` 的数值（回看第 6 节的 flag 位编号）。
5. `P | RW | PS` 的数值（回看第 6 节的 flag 位编号）。
6. PML4[0]、PDPT[0]、PD[0] 各自应该保存什么 64 位数值；注意这不是该 entry 自身的物理地址。
7. `0x1000`、`0x2000`、`0x3000` 为什么都是 4 KiB 对齐。

## 红灯

当前 `setup_page_tables` 会把三张表清零，但预留的 30 字节仍全是 NOP。运行：

```sh
make check-page-tables
```

测试应该先证明 debug console 已收到 `HelloPT`，再报告三个期望 entry 与实际零值。把完整错误记入 `notes/note-10.md`。

## 练习

在 `setup_page_tables` 中，用三条以下形式的指令替换 `times 0x1e db 0x90`：

```asm
mov dword [absolute_address], immediate
```

三条指令分别完成：

1. 让 `PML4[0]` 指向 PDPT。
2. 让 `PDPT[0]` 指向 PD。
3. 让 `PD[0]` 直接映射物理地址 0 开始的 2 MiB large page。

不要修改清零循环、`RET`、测试期待值或页表地址。先根据 entry 布局算出 immediate，再写指令。

完成后运行：

```sh
make check-page-tables
make disassemble-boot
make check-protected
make check-gdt
make check-a20
make check-debugcon
make check-call
make check-segments
```

## 观察题

1. 与分段相比，paging 主要解决了什么地址空间管理问题？
2. 为什么 48 位空间使用多级树，而不是为所有 page 预分配一张平面表？
3. `0x7c00` 和 `0x90000` 的哪些 index 相同？2 MiB leaf 使哪些 bit 不再用作 PT index？
4. 为什么打开 paging 前必须覆盖当前指令地址和栈？恒等映射如何简化切换？
5. `PML4_ADDR equ 0x1000` 和 `REP STOSD` 各自做了什么？为什么页表还必须 4 KiB 对齐？
6. PML4[0]、PDPT[0] 和 PD[0] 中的地址部分与 flags 分别是什么？
7. `PS=1` 改变了页表遍历的哪一步？本课为什么可以省掉 PT？
8. `REP STOSD` 为什么重复 `0x0c00` 次恰好清零三张表？`CLD` 保证了什么？
9. entry 是 64 位，为什么练习只写低 32 位仍然正确？高 32 位由谁置零？
10. 为什么 `make check-page-tables` 通过仍不能说明 paging 或 long mode 已经开启？

## 完成标准

- 先观察到三个实际 entry 全为 0 的红灯。
- 仅用三条 32 位内存写入使 `make check-page-tables` 通过。
- 能从地址和 flags 推导三个 entry，而不是背十六进制常量。
- 能说明 2 MiB page 为什么省掉 PT，以及恒等映射保护了哪些当前地址。
- 能区分“页表存在”与“CPU 已开启 paging”。
- 保护模式、GDT、A20、字符串、调用栈、段寄存器与启动扇区测试全部回归通过。
