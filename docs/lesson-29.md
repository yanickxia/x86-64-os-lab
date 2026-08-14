# 第 29 课：把四个 frame 连成一条 4 KiB 映射

第 26 课让 PMM 能把 free frame 转交给 kernel；第 27 课让 C 能通过 HHDM 访问并清零这些 frame；第 28 课又先建立了 `#PF` 诊断安全网。

现在三项前提终于齐了：

```text
ownership：这些 frame 已经属于 kernel
access：    kernel 有 HHDM VA 可以写它们
diagnosis：地址翻译出错时能看到 CR2/error/RIP
```

本课才开始真正构造 kernel-owned page tables。我们会用四个 4 KiB frame 分别充当 PML4、PDPT、PD 和 PT，把一个固定 VA 映射到第 27 课已经准备好的 data frame。

但本课**不加载新 CR3**。先检查内存中的数据结构正确，再在下一课处理激活；否则一条错误 entry 可能让当前代码、栈、HHDM 和异常入口同时消失，只留下难以区分的重启。

```text
本课：allocate → clear → link → inspect，active CR3 不变
下课：补齐存活映射 → load CR3 → 用 CPU 实际访问目标 VA
```

## 先修知识

开始前只需掌握：

1. PMM 返回 PA 数字，并转移 frame ownership；
2. C 必须用 `HHDM offset + PA` 得到可解引用 VA；
3. 一张 4 KiB page-table page 有 `4096 / 8 = 512` 个 64-bit entries；
4. x86-64 的 4 KiB translation path 是 `PML4 → PDPT → PD → PT → frame`；
5. `Present` 和 `Writable` 是 entry 低位 flags；
6. `CR3` 指向 CPU 当前使用的根表 PA。

不知道某个 C 写法时，可随时回到 [Freestanding C 与内核代码参考](reference/c-basics.md)。

## 本课只引入一个机制

唯一由你实现的新机制是：**把一组已经分配、已经清零的 table frames 连成一条 4 KiB mapping path**。

```c
bool vmm_map_single_4k(struct vmm_page_table_path *path,
                       uint64_t virtual_address,
                       uint64_t physical_address);
```

本课不做：

- page-table frame 的动态查找或复用；
- 遍历已有 entry；
- 覆盖冲突检查和 unmap；
- large page；
- user/supervisor、NX、cache policy 等完整权限模型；
- 加载 `CR3` 或刷新 TLB；
- 建立完整 kernel address-space layout。

这些会在当前最小 path 被机器证据验证后逐步加入。

## 1. 从一个 VA 到四个数组下标

在当前四级、4 KiB page 模式下，一个 canonical VA 被分成：

```text
63             48 47       39 38       30 29       21 20       12 11        0
+----------------+-----------+-----------+-----------+-----------+-----------+
| canonical sign | PML4 index| PDPT index|  PD index |  PT index |page offset|
+----------------+-----------+-----------+-----------+-----------+-----------+
                         9 bits      9 bits      9 bits      9 bits    12 bits
```

每个 table page 有 512 entries，而 `512 = 2^9`，所以每一级正好消费 9 bits。最后 12 bits 是页内 offset，因为 `4096 = 2^12`。

本课固定：

```c
#define LESSON_VMM_TARGET_ADDRESS UINT64_C(0x0000123456789000)
```

它是 4 KiB aligned，offset 为 0。索引公式已由脚手架写进 `kernel/vmm.h`：

```c
#define VMM_PML4_INDEX(address) (((address) >> 39) & UINT64_C(0x1ff))
#define VMM_PDPT_INDEX(address) (((address) >> 30) & UINT64_C(0x1ff))
#define VMM_PD_INDEX(address)   (((address) >> 21) & UINT64_C(0x1ff))
#define VMM_PT_INDEX(address)   (((address) >> 12) & UINT64_C(0x1ff))
```

`0x1ff` 是 9 个 1，确保只保留当前一级的 9 bits。

本课不要求背 shift 数字；要理解的是：同一个 VA 分别选择四张 table 中的一个 entry，而不是四次都访问 index 0。

## 2. 为什么“一条 mapping”先需要四个 table frames

从一棵全空的 page-table tree 开始，CPU 要走完四级，所以至少要有：

```text
PML4 page    root
PDPT page    PML4E 指向它
PD page      PDPTE 指向它
PT page      PDE 指向它
data frame   PTE 最终指向它
```

这里有四个 **table frames**，外加一个被映射的 **data frame**。不要把它说成“五级页表”；data frame 是 translation 的结果，不是下一层 page table。

这也不表示以后每映射 4 KiB 都要再分配四张表。同一路径前缀可以复用：

- 相邻 4 KiB pages 通常只占用同一 PT 的不同 PTE；
- 一个 PT 有 512 entries，可覆盖 `512 × 4 KiB = 2 MiB`；
- 一个 PD entry 指向一个 PT，因此同一 PD 可以继续挂更多 PT。

本课故意从全零 path 开始，是为了把每一级角色看清楚；后续通用 mapper 才会“已有就复用，没有才分配”。

## 3. entry 中放 PA，不放 HHDM VA

`struct vmm_page_table_path` 同时保存两套地址：

```c
struct vmm_page_table_path {
    uint64_t pml4_pa;
    uint64_t pdpt_pa;
    uint64_t pd_pa;
    uint64_t pt_pa;
    uint64_t *pml4;
    uint64_t *pdpt;
    uint64_t *pd;
    uint64_t *pt;
};
```

它们服务于不同消费者：

| 字段 | 谁消费 | 用途 |
| --- | --- | --- |
| `*_pa` | CPU/MMU 与 page-table entries | 指向物理 frame |
| `uint64_t *` | 当前运行的 C 代码 | 通过 HHDM 写 table contents |

例如，脚手架观察到：

```text
PDPT PA       = 0x0000000000002000
PDPT HHDM VA  = 0xffff800000002000
```

C 用第二个地址写内存，但 PML4E 必须编码第一个地址：

```text
正确：PML4E = 0x2000 | flags
错误：PML4E = 0xffff800000002000 | flags
```

原因不是“课程偏好”，而是 page walk 从 `CR3` 给出的物理根地址开始；MMU 读取 parent entry 后需要下一层的物理 frame 编号。HHDM 是当前地址空间给软件提供的 mapping，不是 page-table entry 的替代编码。

## 4. parent entry 和 leaf entry 长得相似，角色不同

本课只使用两个 flags：

```c
#define VMM_PAGE_PRESENT  UINT64_C(1)
#define VMM_PAGE_WRITABLE (UINT64_C(1) << 1)
```

因此 `flags = 0x3`。

四个 entry 的角色为：

```text
PML4E = PDPT PA   | 0x3    parent: 指向下一层 table
PDPTE = PD PA     | 0x3    parent: 指向下一层 table
PDE   = PT PA     | 0x3    parent: 指向下一层 table
PTE   = target PA | 0x3    leaf:   指向最终 data frame
```

它们都把 4 KiB-aligned PA 放在高位，把 flags 放在低 12 bits。alignment 让 PA 的低 12 bits 原本就是 0，因此地址和 flags 可以用 bitwise OR 共存。

本课使用：

```c
#define VMM_PAGE_ADDRESS_MASK UINT64_C(0x000ffffffffff000)
```

它表达课程当前使用的 4 KiB page-address 槽位。生产内核还会根据 `CPUID.MAXPHYADDR` 和不同 entry 类型检查 reserved bits；本课 frames 都位于低物理内存，暂不扩展这条支线。

## 5. `PTE = 0x3` 为什么不是空 entry

第 26 课已经观察到，当前固定 QEMU memory map 的第一个可分配 frame 是 PA `0x0`。本课把它作为 target data frame。

因此 leaf 为：

```text
target PA = 0x0000
flags     = 0x0003
PTE       = 0x0003
```

这是一条合法的 present/writable mapping：地址字段为物理 frame 0，bit 0 仍为 1。

不要用 `entry != 0` 代替 `Present` 检查，也不要因为 PA 是 0 就把它当作 allocation failure。这里再次区分：

```text
PA 0                一个可能有效的物理 frame 编号
NULL pointer        C 接口中的“没有对象指针”
PTE 0               Present=0，没有 mapping
PTE 3               Present=1, Writable=1，映射到 PA 0
```

## 6. 本课 frame 分工是公开输入

为了让实验前计算可以直接从页面推出，脚手架固定沿用 monotonic PMM 的当前顺序：

| 角色 | PA | 来源 |
| --- | ---: | --- |
| target data frame | `0x0000` | 第 26/27 课的 `first_page` |
| PML4 root | `0x1000` | 已分配的 `second_page` |
| PDPT | `0x2000` | 本课随后分配 |
| PD | `0x3000` | 本课随后分配 |
| PT | `0x4000` | 本课随后分配 |

每张 table 都先通过 `hhdm_prepare_page()` 清零，再交给你的函数。你的函数不负责 allocator，也不应再次清零整页。

这张表是当前固定实验输入，不是“所有机器的前五页都能随便使用”。真正的依据仍是 Limine memory map 与 PMM ownership transition。

## 7. 为什么先不加载 CR3

构建正确的数据结构和让 CPU 使用它，是两次不同的状态转换：

```text
build:
  four owned/zeroed frames
    → entries linked in memory
    → active CR3 unchanged

activate:
  new root already maps current RIP/RSP/HHDM/IDT
    → mov cr3, root_pa
    → CPU page walk uses new tree
```

本课的新 root 只有一条 `0x0000123456789000 → PA 0` mapping。它没有映射：

- 当前高半 kernel code；
- 当前 stack；
- debug output code/data；
- HHDM；
- IDT 和 page-fault handler。

如果现在直接 `mov cr3, 0x1000`，取下一条指令本身就可能失败；而 handler 也不在新地址空间中，最终可能升级成 double/triple fault。

所以 `VMM:BUILD:OK` 必须同时伴随：

```text
VMM:ROOT:INACTIVE
active CR3 frame != new PML4 frame
```

它证明 table contents 已准备好，不冒充 CPU 已经使用这条 mapping。

## 8. 你的函数合同

只编辑 `kernel/vmm.c` 中的 `vmm_map_single_4k()`。

输入已经保证 table frames 被分配并清零，但函数仍应拒绝明显无效的调用：

1. `path == NULL` 或四个 HHDM table pointers 中任一个为 `NULL`；
2. 四个 table PA 或 target PA 不是合法的 4 KiB entry address；
3. target VA 不是 4 KiB aligned。

成功路径只写四个 entries：

```text
pml4[PML4_INDEX(VA)] = pdpt_pa | flags
pdpt[PDPT_INDEX(VA)] = pd_pa   | flags
pd[PD_INDEX(VA)]     = pt_pa   | flags
pt[PT_INDEX(VA)]     = target_pa | flags
```

函数不调用 PMM、不做 HHDM 加法、不打印、不读取/写入 `CR3`。这让“allocation / software access / structure construction / activation”四层责任保持分离。

## 9. 当前红灯为什么会亮（先不要运行）

脚手架已经完成：

1. 复用第 28 课 vector 14 安全网；
2. 把 `second_page` 用作 root，再分配 PDPT/PD/PT 三个 frames；
3. 用 HHDM 清零四张 table；
4. 打印 frame PA 与固定 target VA/PA；
5. 调用 `vmm_map_single_4k()`；
6. 无论本课红灯还是绿灯，最后仍触发第 28 课的固定 `#PF`，保证旧课不被遮蔽。

当前 `kernel/vmm.c` 固定返回 `false`，所以可直接推出：

```text
HHDM:PAGE:OK       出现
PF:IDT:OK          出现
VMM:FRAMES:OK      出现
VMM:LINK:FAIL      出现
VMM:BUILD:OK       不出现
PF:DIAG:OK         仍出现
```

这说明 ownership、HHDM 和异常诊断都还成立，红灯只位于“尚未连接四层 entries”。

## 实验前预测

先填写 `notes/note-29.md`，不要运行后覆盖原答案。

### 1. 计算四个 indices

使用第 1 节公式，把 `0x0000123456789000` 分别算出 PML4、PDPT、PD 和 PT index。写十六进制即可；每个结果必须位于 `0..0x1ff`。

### 2. 计算四个 entries

根据第 4、6 节公开的五个 PA 和 `flags=0x3`，计算 PML4E、PDPTE、PDE 与 PTE。

特别解释为什么 target PA 为 0 时，PTE 仍不是 0。

### 3. PA 与 HHDM pointer

若 HHDM offset 为上一课观察到的 `0xffff800000000000`，PDPT PA 为 `0x2000`：

- C 写 PDPT 时使用哪个 VA？
- PML4E 的 address field 应写哪个值？
- 为什么两者不同？

### 4. 当前红灯与旧课证据

根据第 9 节列出 `VMM:FRAMES:OK`、`VMM:LINK:FAIL`、`VMM:BUILD:OK`、`PF:DIAG:OK` 的出现情况，并说明为什么本课红灯不应破坏第 28 课绿灯。

## 10. 第一次运行：确认红灯

完成预测后运行：

```sh
make inspect-kernel-page-table
make check-kernel-page-table
```

预期失败边界为：

```text
table frames 已分配并清零
→ vmm_map_single_4k() 固定返回 false
→ VMM:LINK:FAIL
```

若看不到 `VMM:FRAMES:OK`，属于 allocation/HHDM 脚手架或旧课回归；不要修改 mapper 去掩盖它。

## 11. 实验：连接四个 entries

只编辑 `kernel/vmm.c`。

推荐按以下顺序：

1. 检查 `path` 与四个 table pointers；
2. 检查五个 PA 的 alignment/address bits 与 VA alignment；
3. 计算一次 `flags = PRESENT | WRITABLE`；
4. 用四个 index macros 分别写 parent/leaf entry；
5. 返回 `true`。

### 分级提示

<details>
<summary>提示 1：pointer validation</summary>

```c
if (path == NULL || path->pml4 == NULL || path->pdpt == NULL ||
    path->pd == NULL || path->pt == NULL) {
    return false;
}
```

</details>

<details>
<summary>提示 2：一个 PA 同时检查高位和 alignment</summary>

`VMM_PAGE_ADDRESS_MASK` 只保留 entry 的 address field。若：

```c
(physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0
```

说明低 12 bits 或课程暂不支持的高位中至少有一位不是 0。

</details>

<details>
<summary>提示 3：一条 parent entry</summary>

```c
const uint64_t flags = VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;
path->pml4[VMM_PML4_INDEX(virtual_address)] = path->pdpt_pa | flags;
```

PDPT/PD 两级替换 table pointer、index 和 next-table PA；PT leaf 改用 target `physical_address`。

</details>

## 12. 绿灯取证

完成后运行：

```sh
make check-kernel-page-table
make check-page-fault
make check-hhdm-page
make check-physical-pages
make check-limine-handoff
```

`check-kernel-page-table` 会先验证 QEMU 中的真实四层 path，再用同一个纯 C 函数检查 `NULL`、未对齐 table PA、未对齐 target PA 和未对齐 target VA；不能只让当前一组正常输入碰巧通过。

当前固定输入的完整结构应为：

```text
indices: 0x24 / 0xd1 / 0xb3 / 0x189
entries: 0x2003 → 0x3003 → 0x4003 → 0x0003
new root: 0x1000, inactive
```

`ACTIVE-CR3` 的精确数值由 Limine 当前 page tables 决定，不要写死；本课只要求它的 address field 不等于新 root PA `0x1000`。

## 预测修订

只修订与真实结果不同的项目，不重复抄录所有正确数值：

```text
原预测 → 真实结果 → 哪个输入或哪一步理解错了
```

若四项完全一致，写一行“与真实结果一致”，并引用 `make check-kernel-page-table` 的证据即可。

## 唯一新增的收束题

为什么 `VMM:BUILD:OK` 仍不能证明 CPU 可以通过 `0x0000123456789000` 访问 PA 0？下一课在加载新 `CR3` 前，至少必须先把哪几类当前存活映射复制或重建进去？

这题不重复计算 index/entry；它检查你是否区分了“内存中有一棵树”和“CPU 正在使用且能在其中继续执行”。

## OS 视角（简要）

真正的 VMM 不会为每次 mapping 接收四张现成空表。它通常从 root 开始 walk：parent entry 存在就复用，不存在才向 PMM 申请并清零下一层 frame，最后设置 leaf permissions。

本课的 `vmm_map_single_4k()` 是这个通用 walker 的最小展开形式。它牺牲复用能力，换来一条能逐级检查的确定路径；下一步再把它扩展成可激活的 kernel address space。

## 官方与配套参考

- [Intel 64 and IA-32 SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)（Volume 3A：Paging，4-Level Paging entries）
- [AMD64 Architecture Programmer's Manual Volume 2](https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2)（Long-Mode Page Translation）
- [xv6 book 2025](https://pdos.csail.mit.edu/6.1810/2025/xv6/book-riscv-rev5.pdf)（Chapter 3：Page tables；层数不同，但 walk/allocate/map 的 OS 角色相同）
- [MIT 6.1810 page-table lab](https://pdos.csail.mit.edu/6.1810/2025/labs/pgtbl.html)（观察 page-table entry 与 VA/PA/permissions 的关系）

## 完成标准

- 能从 VA 算出四个 9-bit indices；
- 能区分 table PA、HHDM pointer 和 active CR3；
- 能解释 parent entry 指向下一层 table、leaf PTE 指向 data frame；
- `vmm_map_single_4k()` 只连接已准备好的四层 path，不分配、不激活；
- `make check-kernel-page-table` 与四项 Limine 历史回归通过；
- 笔记保留原预测、红灯、实现、绿灯和简短预测修订，不重复回答已经验证过的计算题。
