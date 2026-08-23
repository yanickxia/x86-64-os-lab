# 第 31.5 课：把 PA、VA、PMM、VMM、PTE 与 HHDM 串成一条线

## 本章定位

第 31 课已经让 `#PF` 补上一条 leaf PTE，第 32 课将让 kernel 从 root 和 fault VA 自己找到这条 PTE。两课之间容易被一串相似名词遮住真正的主线：

```text
PMM 分配 physical frame
        ↓
kernel 通过 HHDM 访问 frame 或 page-table page
        ↓
VMM 把 frame PA 写进 PTE
        ↓
MMU 按页表把程序使用的 VA 翻译成 PA
```

本章不引入代码和实验，只把这条链路讲清楚。读完后再看第 32 课，目标应当很具体：**给定 root PA 与 VA，沿已有的 parent entries 找到最后那个可以读取或填写的 64-bit PTE slot。**

## 1. 先抛开虚拟化：裸机只有 VA 与 PA

假设 kernel 直接运行在真实 x86-64 机器上，不考虑 QEMU、宿主操作系统或 guest/host 转换。CPU 访问内存时的主链只有两层：

```text
程序或 kernel 发出 virtual address（VA）
                  ↓
             CPU 的 MMU
                  ↓ 查当前页表
system physical address（PA）
                  ↓
             RAM 或 MMIO
```

PA 是机器的 **system physical address**。物理地址空间不保证全部对应 RAM，其中还可能有 firmware reserved area、设备 MMIO 和地址空洞。因此 PMM 不能随便从 0 开始发号，而只能消费 bootloader memory map 中允许 kernel 使用的 RAM 范围。

在 QEMU 实验中，这些 PA 更准确地说是 guest PA，由 QEMU 在背后提供内存；但从 guest kernel 的职责看，PMM、CR3 与 PTE 管理的仍然都是“本机 PA”。学习页表时先使用上面的裸机模型，不需要再加入宿主机器这一层。

## 2. C 指针不天然等于 VA，但在当前内核里按 VA 使用

C 语言标准只定义 pointer，并不知道 x86 页表，也不规定某个数值是 VA 还是 PA。真正的含义取决于运行环境。

当前 kernel 已进入 x86-64 long mode，而 long mode 必须开启 paging。编译器生成普通 load/store 后，CPU 会把指令形成的线性地址交给 MMU。因此在本课程当前环境中，可以把普通 C pointer 理解为 VA：

```c
uint8_t *pointer = (uint8_t *)0x12345000;
uint8_t value = *pointer;
```

这段代码不会告诉 CPU“请读取 PA `0x12345000`”。它表达的是：

```text
读取 VA 0x12345000
       ↓
MMU 查询当前页表
       ↓
得到某个 PA，或者因为 mapping 不存在而触发 #PF
```

只有以下特殊情形中，pointer 的数值才会与 PA 看起来相同：

- paging 关闭，线性地址不再经过页表；
- 页表主动建立了 `VA x → PA x` 的 identity mapping；
- 没有 MMU 的简单裸机系统直接使用物理地址。

即使是 identity mapping，CPU 仍然执行了一次 VA → PA 翻译，只是两边的数值恰好相等。

## 3. PMM 返回的是 PA，不是可以直接解引用的 pointer

PMM（Physical Memory Manager）管理 physical frame 的 ownership。一次：

```c
uint64_t frame_pa = pmm_alloc_page();
```

可能返回：

```text
frame_pa = 0x12345000
```

这表示 kernel 取得了下面 4 KiB 物理范围的 ownership：

```text
[0x12345000, 0x12346000)
```

最后一个 byte 是 `0x12345fff`。4 KiB 是 `0x1000` bytes，所以相邻 frame 的起点相差 `0x1000`，不是 `0x100` 或 `0x500`。

PMM 返回的 PA 可以：

- 保存为整数；
- 与对齐和范围合同比较；
- 写进 `CR3` 或 page-table entry 的 address bits；
- 先转换成某个有效 VA，再由 C pointer 访问内容。

不能仅仅因为这个数字来自 PMM，就直接把它强转成 pointer 并解引用。CPU 不会追踪一个整数的来源。

## 4. HHDM 是 kernel 访问物理内存的固定虚拟窗口

HHDM（Higher Half Direct Map）预先建立一组规则映射：

```text
HHDM VA = hhdm_offset + PA
```

假设：

```text
hhdm_offset = 0xffff800000000000
frame PA    = 0x0000000012345000
```

对应的 HHDM VA 是：

```text
0xffff800012345000
```

页表已经保证：

```text
VA 0xffff800012345000 → PA 0x0000000012345000
```

于是 kernel 可以使用普通 C pointer 访问这个 physical frame：

```c
uint64_t *frame = (uint64_t *)(uintptr_t)(hhdm_offset + frame_pa);
frame[0] = 0;
```

HHDM 没有复制或移动 frame，也没有把一个“不真实的地址”变成真实地址。它只为同一块物理内存提供一个可由 kernel C 代码解引用的 VA。

同一个 frame 还可以同时拥有其他 VA alias：

```text
custom VA 0x000012345678a000 ─┐
                              ├─→ PA 0x5000 → 同一块 RAM
HHDM VA   0xffff800000005000 ─┘
```

通过任一 VA 写入，都能从另一个 VA 读到同一内容。

## 5. 页表 entry 里必须放 PA，不能放 HHDM VA

HHDM 是给 kernel 软件使用的访问窗口；MMU page-table walker 按架构要求读取的则是 physical address。

因此：

```text
CR3 address bits       = PML4 的 PA
PML4E address bits     = 下一张 PDPT 的 PA
PDPTE address bits     = 下一张 PD 的 PA
PDE address bits       = 下一张 PT 的 PA
4 KiB leaf PTE address = 最终 data frame 的 PA
```

绝不能把 `hhdm_offset + pa` 写进这些 address bits。正确区别是：

```c
/* 写给 MMU 看的 entry：使用 PA。 */
pte[index] = frame_pa | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;

/* kernel C 要访问那一页：使用 HHDM VA。 */
uint64_t *frame = (uint64_t *)(uintptr_t)(hhdm_offset + frame_pa);
```

## 6. 四级页表不是“每个地址准备四张新表”

每张 4 KiB page-table page 包含 512 个 64-bit entries：

```text
4096 bytes / 8 bytes = 512 entries
```

构造一条新路径时，通常先把新 table frame 的整页清零，所以它一开始有 512 个 absent entries。随后只填写目标 VA 所经过的少数 slots；其余 entries 继续为 0，留给其他虚拟地址路径以后使用。

对：

```text
VA = 0x0000123456789000
```

四个 9-bit indices 是：

```text
PML4 index = 0x024
PDPT index = 0x0d1
PD index   = 0x0b3
PT index   = 0x189
offset     = 0x000
```

假设课程中人工分配了：

```text
PML4 PA = 0x1000
PDPT PA = 0x2000
PD PA   = 0x3000
PT PA   = 0x4000
data PA = 0x0000
```

实际只需在这四张已经清零的表中发布一条路径：

```text
PML4[0x024] = 0x2000 | 0x3 = 0x2003
PDPT[0x0d1] = 0x3000 | 0x3 = 0x3003
PD[0x0b3]   = 0x4000 | 0x3 = 0x4003
PT[0x189]   = 0x0000 | 0x3 = 0x0003
```

所以“`PML4[0x24] → PDPT`”的准确含义是：

> PML4 的第 `0x24` 个 64-bit entry，其 address bits 保存 PDPT 所在 physical frame 的起点 PA `0x2000`。

它不是指向整个抽象名称“PDPT”，也不是保存 C pointer。若 kernel 自己要读取这张 PDPT，会计算：

```text
PDPT C pointer = hhdm_offset + 0x2000
```

## 7. entry 自己在哪里，与 entry 保存什么，是两回事

以 `PML4[0x24]` 为例：

- PML4 page 的 PA 是 `0x1000`；
- 一个 entry 占 8 bytes；
- 第 `0x24` 项本身位于 PA `0x1000 + 0x24 × 8 = 0x1120`；
- 这 8 bytes 中保存的值是 `0x2003`；
- `0x2003` 的 address bits `0x2000` 指向下一张 PDPT page。

继续计算，本课程这条路径上的 entry 位置是：

| slot | entry 自身所在的 PA | entry value | address bits 的含义 |
| --- | ---: | ---: | --- |
| `PML4[0x24]` | `0x1120` | `0x2003` | PDPT PA `0x2000` |
| `PDPT[0xd1]` | `0x2688` | `0x3003` | PD PA `0x3000` |
| `PD[0xb3]` | `0x3598` | `0x4003` | PT PA `0x4000` |
| `PT[0x189]` | `0x4c48` | `0x0003` | data frame PA `0x0000` |

“entry 的存放地址”和“entry 内编码的下一层地址”不能混为一谈。

## 8. `VMM_PAGE_ADDRESS_MASK` 不参与 VA index 计算

两类操作使用不同输入：

```text
从 VA 取 index：            对 virtual_address 位移并取 9 bit
从 entry 取下一层 PA：      entry & VMM_PAGE_ADDRESS_MASK
```

例如：

```c
size_t pml4_index = (virtual_address >> 39) & 0x1ff;
uint64_t next_pa = entry & VMM_PAGE_ADDRESS_MASK;
```

`VMM_PAGE_ADDRESS_MASK` 的任务是从 entry 中清掉低位 flags，留下 page-aligned physical address bits。例如：

```text
entry                       = 0x0000000000005003
VMM_PAGE_ADDRESS_MASK       = 0x000ffffffffff000
entry & ADDRESS_MASK        = 0x0000000000005000
```

它不会改变，也不会参与 `0x24 / 0xd1 / 0xb3 / 0x189` 这些 index 的计算。

## 9. 当前 PMM 到底怎样管理内存

当前 PMM 是 monotonic/bump allocator，可以把它想成“沿着 `USABLE` ranges 向前移动的 4 KiB cursor”：

```text
memory map 中找到可用 range
        ↓
对齐到 4 KiB frame boundary
        ↓
返回 current PA
        ↓
cursor += 0x1000
        ↓
range 用尽后进入下一个 USABLE range
```

它还维护 `free_pages` 与 `allocated_pages` 等 counter，但目前没有 `free()`，因此已经发出的 frame 不会重新进入候选集合。

PMM 只解决 ownership：哪一个 physical frame 已经交给 kernel 的某个 subsystem。它不会自动：

- 清零 frame；
- 创建 VA → PA mapping；
- 修改 Limine memory-map entry；
- 回收 frame。

课程中的 `0x0000、0x1000、…、0x5000` 是实验环境里 PMM 恰好依次拿到的 frame PAs，不是 PMM 的普遍规定。在真实机器上，第一次可用 frame 完全可能是 `0x12345000`。

## 10. 第 31 课的 demand mapping 如何接上 PMM

当前实验为了避免在 exception path 中引入 allocator 的锁和重入问题，在 fault 之前已经预留：

```text
demand data frame PA = 0x5000
```

目标 VA 是：

```text
0x000012345678a000
```

它与上一页共用 PML4、PDPT、PD 和 PT，只是 leaf index 从 `0x189` 变为 `0x18a`：

```text
PT[0x189] = 0x0003    已映射到 frame PA 0
PT[0x18a] = 0         demand mapping 尚未发布
```

第一次 store 的完整过程是：

```text
1. C store 使用 VA 0x000012345678a000
2. MMU 从 CR3 开始执行 hardware walk
3. MMU 到达 PT[0x18a]，发现 PRESENT=0
4. CPU 触发 #PF，CR2 保存 fault VA
5. kernel handler 确认这是允许恢复的 write
6. kernel 把 PT[0x18a] 改为 0x5000 | 0x3 = 0x5003
7. INVLPG 失效该 VA 的旧翻译状态
8. IRETQ 回到同一条 store
9. CPU 重试，MMU 得到 PA 0x5000
10. store 写入 physical frame [0x5000, 0x6000)
```

这里不是“VMM 触发 page fault”。触发 fault 的是 CPU/MMU；VMM 是 kernel 中负责解释 fault 并管理 mapping 的软件。

## 11. 第 32 课为什么还要“让 kernel 自己找 leaf PTE”

CPU 的 hardware walker 会为一次 load/store 找到最终 PA，或者触发 `#PF`，但不会把下面这个管理对象作为 C pointer 返回给 kernel：

```text
&PT[0x18a]
```

第 31 课绕过了这个问题：实验驱动事先保存了 `demand_page.pte`。真实 VMM 通常只拿到：

```text
active root PA + fault VA + HHDM offset
```

因此第 32 课的软件 walker 要重复的是“管理路径”，而不是替 CPU 完成实际内存访问：

```text
root PML4 PA
  │ 通过 HHDM 得到 PML4 C pointer
  ▼
读取 PML4[VA index]，mask 出 PDPT PA
  │ 通过 HHDM 得到 PDPT C pointer
  ▼
读取 PDPT[VA index]，mask 出 PD PA
  │ 通过 HHDM 得到 PD C pointer
  ▼
读取 PD[VA index]，mask 出 PT PA
  │ 通过 HHDM 得到 PT C pointer
  ▼
返回 &PT[VA index]
```

注意最后返回的是 **PTE slot 的 pointer**，不是 data frame pointer，也不是 PTE 当前保存的数值。caller 得到 slot 后才能决定：

- `*pte == 0`：parent path 存在，但 leaf mapping 缺失，可以填写；
- `*pte & PRESENT`：mapping 已存在，可以检查 PA 或 flags；
- 清除或修改 `*pte`：执行后续 unmap、权限调整或 copy-on-write policy。

## 12. 一张最终术语表

| 名词 | 当前课程中的含义 | 典型内容 |
| --- | --- | --- |
| virtual page | VA 对齐到 4 KiB 后的一页 | `0x000012345678a000` |
| physical frame | PA 对齐到 4 KiB 后的一页 RAM | `[0x5000, 0x6000)` |
| PMM | 分配和跟踪 physical-frame ownership | 返回 PA `0x5000` |
| VMM | 建立、查询、修改 VA → PA mapping | 修改 leaf PTE |
| MMU | CPU 中执行实际地址翻译的硬件 | hardware page-table walk |
| page-table page | 保存 512 个 entries 的 physical frame | PML4/PDPT/PD/PT frame |
| parent entry | 保存下一张 page-table page 的 PA + flags | `0x2003` |
| leaf PTE | 保存最终 data frame 的 PA + flags | `0x5003` |
| HHDM | 让 kernel C 访问 physical memory 的规则 VA mapping | `VA = offset + PA` |
| `VMM_PAGE_ADDRESS_MASK` | 从 entry 中取出 PA，清掉 flags | `0x5003 → 0x5000` |
| `CR3` | active page-table root 的 PA 加控制位 | 指向 PML4 frame |

## 进入第 32 课前只保留五句话

1. PMM 返回 PA；它描述 physical frame ownership，不是可直接解引用的 C pointer。
2. 当前 long-mode kernel 中，普通 C pointer 按 VA 使用；访问任意 PA 前必须先有某个 VA mapping。
3. HHDM 用固定 offset 给 physical memory 提供 kernel VA，但 page-table entries 中仍然只写 PA。
4. VA 决定四级 indices；address mask 从 entry 中提取下一张 table 或最终 frame 的 PA，两者互不混用。
5. 第 32 课的软件 walker 要返回 leaf PTE slot 的 C pointer，让 kernel 能读取或修改 mapping；它不是替 MMU 读取最终 data frame。
