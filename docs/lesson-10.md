# 第 10 课：构造低 2 MiB 恒等映射

## 先修知识

开始前应能用上一课的证据说明：

- CPU 已处于 32 位保护模式，`CR0.PE=1`。
- `CS=0x08` 选中 32 位 code descriptor。
- `DS=ES=SS=0x10`，这些 descriptor 的 base 都是 0。
- `ESP=0x00090000`，当前代码位于 `0x00007c00` 附近。

本课会首次使用 `EDI`、`ECX`、`CLD`、`REP STOSD` 和 `mov dword [absolute_address], immediate`。这些语法在练习前都会解释，不需要预先会写。

硬件参考：

- [Intel SDM Volume 1](https://cdrdv2.intel.com/v1/dl/getContent/671436) 的 “Memory Organization” 与 “Addressing”。
- [Intel SDM Volume 3A](https://cdrdv2.intel.com/v1/dl/getContent/671190) 的 “Protected-Mode Memory Management” 与 “Paging”。
- [AMD64 Architecture Programmer's Manual, Volume 2](https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2) 的 “Memory System”。

## 本课只引入一个机制

在物理内存中构造一条有效的页表链，把低 2 MiB 线性地址恒等映射到同数值的物理地址：

```text
PML4[0] → PDPT[0] → PD[0, PS=1] → 2 MiB physical page at 0
```

本课不加载 `CR3`，不设置 `CR4.PAE`，不设置 `EFER.LME`，也不打开 `CR0.PG`。页表完成后仍然只是内存中的数据结构；下一课才让 CPU 真正走这条翻译路径。

## 1. 一次内存访问到底经过哪些地址

“逻辑地址 → 线性地址 → 物理地址”不是三种内存，而是同一次访问在不同翻译阶段的名字。先把完整路径展开：

```text
instruction registers/immediate
              │
              │ 计算 effective address（offset）
              v
      segment selector : offset
              │
              │ segmentation
              │ segment base + offset，并检查段规则
              v
        linear address
              │
              │ paging（CR0.PG=1 时）
              │ CR3 + page-table walk
              v
        physical address
              │
              v
       cache / RAM / MMIO
```

### 1.1 四个术语不要混用

| 术语 | 它是什么 | 本课程中的例子 |
| --- | --- | --- |
| effective address / offset | 指令用寄存器、比例、位移算出的段内偏移 | `0x7c00` |
| logical address | segment selector 与 offset 组成的地址 | `DS:0x7c00`，其中 `DS=0x10` |
| linear address | segmentation 的结果，也是 paging 的输入 | `0x00007c00` |
| physical address | paging 的结果，最终指向 RAM 或 MMIO | 恒等映射下仍为 `0x00007c00` |

现代操作系统教材常把 linear address 直接称为 virtual address。原因是主流 x86-64 内核使用 flat segmentation，程序看到的指针数值通常就是 linear/virtual address。Intel 手册为了描述完整硬件路径，仍严格区分 logical、linear 和 physical。

例如指令：

```asm
mov eax, [ebx + esi * 4 + 0x20]
```

CPU 先计算：

```text
offset = EBX + ESI × 4 + 0x20
```

普通数据访问默认使用 `DS`，因此完整的 logical address 是 `DS:offset`。指令取指默认使用 `CS:EIP`，栈访问使用 `SS:ESP`；某些寻址形式默认使用 `SS`，也可以用 segment override 改成 `FS:` 或 `GS:`。所以源码中看不到 selector，不代表 segmentation 没有参与。

### 1.2 segmentation：给 offset 选择一个线性地址窗口

8086 的段寄存器直接参与算术：

```text
linear address = segment × 16 + offset
```

例如：

```text
1234:5678 → 0x1234 × 16 + 0x5678 = 0x179b8
```

80286 引入保护模式后，段寄存器中的可见值不再是 base，而是 selector。加载 `DS=0x10` 时，CPU 用 selector 的 index 在 GDT 中找到 descriptor，并把 descriptor 的 base、limit、类型和权限缓存到段寄存器的隐藏部分。后续访问在概念上执行：

```text
linear address = cached segment base + offset
```

同时检查 offset 是否越过 limit、段类型是否允许这次读写、当前特权级是否合适。违反段规则通常产生 `#GP`；栈段相关问题通常产生 `#SS`。这些错误发生在 paging 之前，因此此时还没有物理地址。

当前课程使用 flat segmentation：

```text
DS selector  = 0x10
GDT index    = 0x10 >> 3 = 2
cached base  = 0
offset       = 0x7c00

linear address = 0 + 0x7c00 = 0x7c00
```

“selector 为 `0x10`”与“base 为 `0x10`”完全不是一回事。`0x10` 只是找到 GDT 第 2 项的索引编码；真正参与加法的是该 descriptor 缓存下来的 base，本课中它恰好为 0。

若另一个 descriptor 的 base 为 `0x00400000`，同一个 offset `0x1234` 会得到：

```text
logical address = selector:0x1234
linear address  = 0x00400000 + 0x1234
                = 0x00401234
```

这就是 segmentation 的核心能力：重定位一个地址区域，并在进入 paging 之前施加粗粒度保护。

### 1.3 paging：决定一个线性 page 由哪个物理 frame 承载

当 `CR0.PG=0` 时，不进行页表翻译，linear address 直接作为 physical address 使用。在传统 PC 上，A20 gate 还可能在地址送到内存系统前影响 bit 20；这就是第 7 课单独处理 A20 的原因。

当 `CR0.PG=1` 时，CPU 把 linear address 拆成 page-table index 和 page offset。`CR3` 给出根页表的物理地址；中间 entry 给出下一级表的物理地址；leaf entry 给出最终物理 page frame 的 base：

```text
physical address = leaf frame base + page offset
```

这里有一个容易错过的事实：page-table walk 本身读取的是物理内存。以本课将要启用的表为例，`CR3=0x1000` 告诉 CPU“从物理地址 `0x1000` 的 PML4 开始读”，并不是先用同一套页表翻译 `0x1000`。

page-table entry 不只保存地址，也保存 `P/RW/US/NX` 等权限。最终访问必须同时满足路径上相关 entry 和控制寄存器的规则；entry 不存在或权限不允许时产生 `#PF`。此时 `CR2` 记录的是发生故障的 linear address，而不是一个尚未成功形成的 physical address。

分页带来的关键自由是：两边不必数值相同。

```text
identity mapping
linear 0x00007c00 → physical 0x00007c00

non-identity mapping
linear 0x00007c00 → physical 0x00207c00
```

若把本课 `PD[0]` 的物理 base 从 0 改成 `0x00200000`，同时保留 2 MiB page offset，那么 linear `0x7c00` 就会翻译成 physical `0x207c00`。只有先把代码复制到那个物理位置，CPU 才能继续执行；这解释了为什么进入分页时先使用恒等映射最省事。

分页也使两个进程可以使用相同的 linear address，却由不同 `CR3` 映射到不同 RAM：

```text
process A: linear 0x00400000 → physical frame A
process B: linear 0x00400000 → physical frame B
```

反过来，也可以让多个 linear page 指向同一个 physical frame，从而实现共享内存、共享代码页或 copy-on-write 的基础映射。

### 1.4 用当前代码完整走一遍 `DS:0x7c00`

下一课加载 `CR3` 并开启 paging 后，假设代码读取 logical address `DS:0x7c00`，它会经历以下过程。当前指令取指使用的是 `CS:EIP`，但由于本课 `CS` 的 base 同样为 0，对 `EIP=0x7c00` 的地址计算结果相同。

第一道转换是 segmentation：

```text
logical address = DS:0x00007c00
DS              = 0x10
GDT[2].base     = 0
linear address  = 0 + 0x00007c00
                = 0x00007c00
```

第二道转换是 paging。`0x7c00 < 2 MiB`，所以 PML4、PDPT 和 PD index 都是 0，2 MiB page offset 是 `0x7c00`：

```text
CR3 = physical 0x1000
  │
  ├─ read physical 0x1000: PML4[0] = 0x2003
  │                              next table at physical 0x2000
  │
  ├─ read physical 0x2000: PDPT[0] = 0x3003
  │                              next table at physical 0x3000
  │
  └─ read physical 0x3000: PD[0]   = 0x0083
                                 PS=1, physical base=0

physical address = 0 + 0x7c00 = 0x7c00
```

所以这次恰好有两个“数值没变”：

```text
segment base = 0       → offset = linear
page frame base = 0    → linear = physical（低 2 MiB 内）
```

它们是两个独立设计选择，不是一条硬件定律。只要把 segment base 或 page mapping 改掉，三个地址就会不同。

### 1.5 历史上为什么两套机制会叠在一起

这条看似复杂的流水线来自兼容演化，而不是一次设计出来的：

1. 8086 用 `segment × 16 + offset` 让 16 位寄存器组合出 20 位地址，主要目标是扩大寻址范围。
2. 80286 把 segment 变成 descriptor，加入 base、limit、类型和 privilege，主要目标是保护与多任务。
3. 80386 保留 segmentation 兼容旧软件，又在其结果后加入 paging，用固定大小 page 解决地址空间隔离、稀疏分配和物理内存管理。
4. x86-64 继续保留这套历史接口，但现代内核通常把 segmentation 配成 flat model，把地址空间虚拟化的主要工作交给 paging。

仅靠大小不同的 segment 管理现代地址空间会遇到：

- 物理内存外部碎片。
- segment 增长时可能需要搬动。
- 以整个 segment 换入换出过于粗糙。
- 难以低成本表示稀疏地址空间。

固定大小 page 让操作系统可以逐页分配、回收、共享、换出和设置权限；多级页表又避免为空洞区域预分配大量 entry。

### 1.6 为什么 32 位操作系统后来也很少谈 segmentation

32 位保护模式不能关闭 segmentation：每次访问仍然要经过 `CS/DS/ES/SS` 对应 descriptor 的 base、limit 和权限规则。但 Linux、JOS 等现代 32 位内核通常采用 flat segmentation：

```text
kernel code/data segment: base=0, limit=4 GiB, DPL=0
user code/data segment:   base=0, limit=4 GiB, DPL=3
```

于是普通地址的数值同样不变：

```text
logical offset 0x08048000
    --segment base 0--> linear 0x08048000
    --paging----------> 某个 physical frame
```

内核态与用户态仍使用不同的 `CS/SS` selector，segment descriptor 继续帮助 CPU 判断 CPL/DPL；但进程的地址空间隔离不依赖“给每个进程不同的 segment base”，而是让各进程使用不同 `CR3` 和 page tables。同一个用户 linear address 因此可以在两个进程中落到不同物理页。

这正是 MIT 6.828 的 32 位 JOS 实验给人的体验：启动早期配置一次 GDT；之后内存实验主要围绕 page directory、page table、`CR3`、缺页异常和用户映射。segment 通常只在 ring 0/ring 3 切换、trap、TSS、TLS 或少数兼容机制附近重新出现。

为什么操作系统主动把强大的 segmentation 配置得近乎透明？因为 paging 更适合现代虚拟内存：它能以固定大小 page 实现稀疏分配、逐页权限、共享、copy-on-write、按需调页和 `mmap`，同时保留 C/Unix 所期待的平坦指针模型。

所以“后来直接学 paging”并不表示 CPU 跳过了 segmentation，而是：

```text
32 位：segmentation 仍强制存在，但被 flat model 配置成数值透明
64 位：架构进一步弱化普通 segmentation，paging 仍是主体
```

### 1.7 long mode 中 segmentation 去了哪里

严格地说，long mode 包含 64-bit mode 与 compatibility mode。进入 64-bit mode 后：

- `CS/DS/ES/SS` 的 base 被视为 0，segment limit 通常不参与地址检查。
- `CS` 仍携带当前特权级和代码执行属性，selector/descriptor 并非毫无作用。
- `FS` 和 `GS` 的 base 仍然有效，操作系统常用它们访问线程局部存储或 per-CPU 数据。
- paging 是强制机制；linear address 还必须是 canonical address。本课程的四级分页要求 bit 63..48 都复制 bit 47。

因此在我们最终的 64 位内核里，普通地址访问可以近似理解为：

```text
offset ≈ linear/virtual address --paging--> physical address
```

但 `FS:`/`GS:` 访问仍会先加 base，兼容模式仍保留传统 segmentation 行为。说“64 位模式完全没有段”会遗漏这些重要例外。

### 1.8 CPU 会不会每次访问都真的读取 GDT 和四张表

概念上，每次访问都必须满足 segmentation 和 paging 的翻译与权限规则；实现上，CPU 用缓存避免反复读表：

- 加载 segment register 时，descriptor 被放进该段寄存器的隐藏 cache。普通访问直接使用缓存的 base、limit 和权限，不会每次重读 GDT。
- 成功的 linear-page → physical-frame 翻译会进入 TLB。TLB 命中时直接得到 frame 和权限；只有 TLB miss 才需要 hardware page-table walker 读取页表。

所以“page-table walk”是理解结果的正确机器模型，但不能据此误以为每条 `mov` 都必然产生四次额外 RAM 读取。后续修改页表时还必须考虑 TLB 失效，这会在虚拟内存阶段专门学习。

最后把故障归因也钉牢：

| 失败阶段 | 常见原因 | CPU 证据 |
| --- | --- | --- |
| segmentation | segment limit、类型或 privilege 不允许 | `#GP` 或 `#SS` |
| linear-address validation | 64 位地址不 canonical | 通常为 `#GP`，栈访问可能为 `#SS` |
| paging | entry 不 present、读写/用户/NX 权限不允许 | `#PF`，`CR2` 保存 linear address |

现在可以把整条路径压缩成三句话：segment 决定“这个 offset 位于哪段线性空间并允许怎样访问”；paging 决定“这个 linear page 由哪个 physical frame 承载”；flat segment 和 identity mapping 只是分别让两道转换的数值碰巧不变。

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
