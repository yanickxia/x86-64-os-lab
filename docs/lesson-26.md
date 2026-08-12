# 第 26 课：从内存地图到物理页所有权

第 25 课结束时，Limine 已经把一张可信的 memory map 交给高半 C kernel。它回答的是：机器有哪些物理地址范围、每段当前属于什么类型。

但它没有回答另一个会不断变化的问题：

> 某个 `USABLE` range 中，第 17 个 4 KiB 页现在还是空闲，还是已经借给页表、进程或内核对象了？

从本课起，我们不再只是接受启动环境，而是让 kernel 第一次制定并执行资源策略：建立一个最小物理页分配器（physical memory manager，PMM），让两个物理页从 `free` 变成 `kernel-owned`。

## 先修知识

开始前只需要带着第 25 课的四个结论：

1. `memory_map_request.response` 是可解引用的虚拟指针。
2. `entry->base` 是物理地址数值，不是可以直接解引用的 C 指针。
3. 只有 `LIMINE_MEMMAP_USABLE` 表示当前就可供 kernel 使用的 RAM。
4. memory map 是启动时的资源描述；它不会跟随 kernel 的分配动作自动变化。

本课不会要求你再写汇编，也不会建立新页表。

## 本课只引入一个机制

本课唯一新增机制是：

```text
alloc_page()
  选择一个尚未分配的 USABLE 物理页
  → 返回它的物理起始地址
  → 更新 allocator bookkeeping
  → 同一页不能再次返回
```

本课暂不加入：

- `free_page()` 与页复用；
- bitmap、buddy allocator 或每页元数据；
- HHDM 指针转换与页面清零；
- kernel-owned page tables；
- 多核并发与锁。

这不是“假 allocator”。它已经完成 allocator 最核心的职责：在资源说明书之上维护**会变化的所有权状态**。只是当前策略为只进不出的 monotonic/bump allocator。

## 1. 先分清 page、frame、PMM 与 VMM

严格术语中：

- **virtual page**：虚拟地址空间中一个固定大小的块；
- **physical frame**：物理内存中能承载一页内容的固定大小块；
- 页表把 virtual page 映射到 physical frame。

工程代码常把 physical frame 也简称为 physical page，因此函数叫 `pmm_alloc_page()`。它实际返回的是一个 **4 KiB physical frame 的起始物理地址**。

```text
PMM（本课）                         VMM（以后）
哪一个 physical frame 空闲？        某个 virtual page 映射到哪个 frame？
返回 PA，例如 0x00001000            建立 VA → PA 的页表项
不决定进程看到什么虚拟地址          决定地址空间、权限与隔离
```

本课只做左边。分到一个 physical frame 并不等于任何新 virtual address 已经映射到它。

## 2. 为什么以 4 KiB 为所有权单位

x86-64 支持多种页大小，但 4 KiB 是最小的普通分页粒度，也是 Limine protocol 对 `USABLE` 和 `BOOTLOADER_RECLAIMABLE` range 的对齐保证。

如果 allocator 以任意字节为单位，页表仍然只能按页映射和保护，两个所有者就可能落在同一个硬件页中，无法独立设置权限。因此内核先把 RAM 看成一格一格的 frame：

```text
[0x1000, 0x2000)  frame 1
[0x2000, 0x3000)  frame 2
[0x3000, 0x4000)  frame 3
```

这里使用半开区间 `[start, end)`：包含 `start`，不包含 `end`。因此 `[0x1000, 0x4000)` 恰好有：

```text
(0x4000 - 0x1000) / 0x1000 = 3 pages
```

当前课程固定：

```c
#define PMM_PAGE_SIZE UINT64_C(4096)
```

## 3. 不是所有 RAM 类型都能立即进入 free pool

第 25 课看到的 memory map 是带类型的物理 range 列表。本课采取最保守、也最容易证明正确的策略：

| memory-map type | 本课处理 | 原因 |
| --- | --- | --- |
| `USABLE` | 加入 free pages | 协议保证其中没有 executable、bootloader information 或其他有价值数据 |
| `BOOTLOADER_RECLAIMABLE` | 暂不加入 | response、初始栈和 bootloader 页表仍可能位于其中 |
| `EXECUTABLE_AND_MODULES` | 不加入 | kernel/module 内容正在使用 |
| `RESERVED` / `BAD_MEMORY` | 不加入 | 不得使用或不可靠 |
| ACPI / framebuffer 等 | 不加入 | 有各自生命周期或设备语义 |

这里的关键不是“名字带 reclaimable 就等于 free”。`reclaimable` 表示：**满足释放前置条件后可以回收**。

Limine protocol 明确说明：response 及其关联数据结构、初始 stack、bootloader page tables 都位于 `BOOTLOADER_RECLAIMABLE` memory。我们当前仍借用 `response->entries`，也仍运行在 Limine 建立的页表和初始栈上，所以现在把整类内存投入 allocator 会造成 use-after-free 风险。

以后要回收它，至少要先：

1. 复制仍需长期保存的 protocol 数据；
2. 切换到 kernel 自己的 stack；
3. 切换到 kernel-owned page tables；
4. 确认没有 MP trampoline 等仍需保留的数据。

## 4. memory map 是事实快照，allocator 是状态机

本课最重要的图只有这一张：

```text
Limine memory map（只读输入）
    USABLE [base, base + length)
                 │ pmm_init() 统计
                 ▼
allocator: free_pages=N, allocated_pages=0
                 │ pmm_alloc_page()
                 ▼
allocator: free_pages=N-1, allocated_pages=1
                 │ pmm_alloc_page()
                 ▼
allocator: free_pages=N-2, allocated_pages=2
```

两次分配后，Limine entry 的 `type` 仍然是 `USABLE`，`length` 也没有减少。这里的 `USABLE` 应理解为“启动交接时可由 kernel 接管”，不是“此刻仍未被 allocator 借出”。

动态真相在 allocator 的 bookkeeping 中：

```text
FREE  --alloc_page()-->  KERNEL-OWNED
```

本课没有 `free_page()`，所以状态不能反向迁移。

## 5. 本课选择：跨 range 的 monotonic allocator

`kernel/pmm.h` 中的状态如下：

```c
struct pmm_allocator {
    const struct limine_memmap_response *memory_map;
    uint64_t next_entry_index;
    uint64_t next_page;
    uint64_t current_range_end;
    uint64_t free_pages;
    uint64_t allocated_pages;
};
```

各字段分别回答：

| 字段 | 含义 |
| --- | --- |
| `memory_map` | allocator 当前借用的只读资源清单 |
| `next_entry_index` | 下次从哪一个 map entry 继续扫描 |
| `next_page` | 当前 range 内下一页的 PA |
| `current_range_end` | 当前 range 的半开结尾；`next_page >= end` 表示耗尽 |
| `free_pages` | 尚未发出的 `USABLE` pages 数量 |
| `allocated_pages` | 已经发给 kernel 的 pages 数量 |

### 5.1 初始化

`pmm_init()` 做两件事：

1. 把 cursor 全部放到“尚未选中 range”的初始状态；
2. 遍历 memory map，只累计 `USABLE` entry 的 `length / 4096`。

固定版 Limine protocol 保证：

- entries 按 `base` 从低到高排序；
- `USABLE` 的 `base` 和 `length` 都按 4096 对齐；
- `USABLE` 不与其他 entry 重叠。

所以本课不需要先修剪半页，也不需要对 map 排序。这个结论来自固定版本的协议合同，不是所有 firmware memory-map 格式都天然具有的性质。

### 5.2 分配一页

`pmm_alloc_page()` 的控制流是：

```text
free_pages == 0 ? ──是──> 返回失败
        │否
        ▼
当前 range 还有页？ ──否──> 从 next_entry_index 向后找下一个 USABLE entry
        │是                           │
        │                        找不到 → 返回失败
        │                             │找到
        │                   next_page=base, end=base+length
        └─────────────────────────────┘
        ▼
out = next_page
next_page += 4096
free_pages -= 1
allocated_pages += 1
返回成功
```

这是“跨 range”的原因：一个 `USABLE` entry 耗尽后不会立刻宣告整个 allocator 耗尽，而是继续扫描后面的 entries。

### 5.3 它的优点与债务

优点：

- 不需要先为 allocator 自己申请动态内存；
- 状态少，容易证明不会重复发出同一页；
- 足够为下一课分配页表页。

债务：

- 不能释放或复用；
- 无法表达某页归哪个 subsystem/process；
- 不能高效选择特定物理区间；
- 仍借用 bootloader-reclaimable memory 中的 map structures；
- 多核调用时没有锁。

我们会在真正需要这些能力时升级数据结构，而不是现在先实现一套复杂 buddy allocator。

## 6. 物理地址 0 不是本 API 的失败值

Base revision 3 及以后允许 `[0, 0x1000)` 被标为 `USABLE`，而本课使用 revision 6。因此 QEMU 上 allocator **可能合法返回 PA `0x0`**。

这和 C 的 null pointer 不是一回事：

```text
PA 0x0                      物理 frame 编号
(void *)0                  virtual null pointer
```

高半 kernel 并不能用 virtual address 0 直接访问 PA 0；以后若要访问它，仍需使用 HHDM 或其他 mapping。

也正因为 PA 0 可能有效，API 不能用“返回 0 表示失败”。本课使用 `bool + output parameter`：

```c
uint64_t page;
if (pmm_alloc_page(&allocator, &page)) {
    /* page 即使等于 0，也是一项成功结果。 */
}
```

`PMM_NO_PAGE` 只用于调用前初始化观察变量，真正成功与否由 `bool` 表达。

## 7. 为什么这课还不需要 HHDM

当前动作只有：

```text
选择一个 frame → 返回 PA 数值 → 更新 ownership counters
```

我们没有读取、写入或清零 frame 的内容，所以还不需要把 PA 转成 C 指针。

下一步当 kernel 想把分到的 frame 用作页表时，就必须：

1. 通过 HHDM 得到可解引用的 VA；
2. 清零整页，避免把垃圾位当成 present page-table entries；
3. 填写页表项；
4. 最终让 CR3 指向 kernel 自己的页表根。

把这两课拆开，是为了先单独证明 ownership，再讨论 mapping 和页面内容。

## 8. 本课新增的最小 C 语法

### 8.1 output parameter

函数要同时返回“成功/失败”和“地址数值”，使用指针作为输出参数：

```c
bool choose(uint64_t *output) {
    if (output == NULL) {
        return false;
    }
    *output = 0x1000;
    return true;
}
```

调用者传入 `&page`，函数内部用 `*output` 写回。

### 8.2 后缀自增

```c
entry = entries[allocator->next_entry_index++];
```

等价于：

```c
entry = entries[allocator->next_entry_index];
allocator->next_entry_index += 1;
```

它确保同一个 entry 不会在下一轮从头重复扫描。

### 8.3 `--` 不是释放

```c
allocator->free_pages--;
```

这里只是计数减一。真正的 ownership transition 还依赖 cursor 已经越过返回的地址，从而不会再次返回同一页。

## 9. 脚手架中的角色与证据边界

| 角色 | 本课是谁 | 边界 |
| --- | --- | --- |
| 资源描述 producer | Limine | 按协议生产 memory-map response |
| 资源描述 consumer | `pmm_init()` | 只读取 `USABLE` ranges |
| ownership manager | `struct pmm_allocator` + `pmm_alloc_page()` | kernel 自己的策略，不属于 Limine 标准 |
| page consumer | 当前由 `limine_kernel_main()` 代替 | 只申请两页做实验；以后会是 page-table/process subsystem |
| observer | `check-physical-pages` | 课程测试，通过 debugcon 检查状态变化 |

出现 `PMM:OK` 能证明：

- 两个返回值不同且 4 KiB 对齐；
- 两个完整 frame 都落在 `USABLE` range；
- `free_pages` 减少 2；
- `allocated_pages` 增加到 2。

它不能证明：

- 页面已经清零；
- HHDM 转换正确；
- 页面已加入某套新页表；
- `free_page()`、并发安全或耗尽路径已经完整实现。

### 9.1 `free_before` 从哪里来

`free_before` **不是 PMM API，也不是 `struct pmm_allocator` 的第七个字段**。它是本课实验驱动在第一次分配前保存的一张只读快照，用来让 observer 比较分配前后的计数：

```c
const uint64_t free_before = allocator.free_pages;
uint64_t first_page = PMM_NO_PAGE;
uint64_t second_page = PMM_NO_PAGE;

pmm_alloc_page(&allocator, &first_page);
pmm_alloc_page(&allocator, &second_page);

/* 此时的 allocator.free_pages 就是输出中的 free_after。 */
```

因此五个观察量的来源并不相同：

| 输出名 | 实际来源 | 是否为 allocator 字段 |
| --- | --- | --- |
| `free_before` | 调用分配前复制的 `allocator.free_pages` | 否，只是局部快照 |
| `first_page` | 第一次调用的 output parameter | 否 |
| `second_page` | 第二次调用的 output parameter | 否 |
| `free_after` | 两次调用后的 `allocator.free_pages` | `free_pages` 是字段；`free_after` 只是输出标签 |
| `allocated_pages` | 两次调用后的 `allocator.allocated_pages` | 是 |

这段代码属于**课程 observer/实验仪器**，不是 allocator 必须向真实 kernel 暴露的一套 API。它要证明的是同一个状态在两次调用之间发生了：

```text
free_pages:      N → N - 2
allocated_pages: 0 → 2
```

之前正文直接使用 `free_before`，却没有先展示这段快照代码，确实缺了一层输入；现已补齐。

## 10. 当前红灯为什么会亮（先不要运行）

先打开 `kernel/pmm.c`。当前两个练习函数都保留同一种最小占位：

```c
(void)allocator;
return false;
```

因此从页面上已经能推出：

```text
LIMINE:ENTRY         会出现：已经进入 kernel
LIMINE:MEMMAP:OK     会出现：第 25 课 handoff 仍成立
PMM:INIT:FAIL        会出现：pmm_init() 固定返回 false
PMM:OK               不会出现：代码在第一次分配前已经 halt
```

`check-physical-pages` 的成功条件不是“程序没有崩溃”，而是看见完整的 counters、两个 PA 和最终 `PMM:OK`，再检查：

```text
first != second
first % 4096 == 0
second % 4096 == 0
allocated == 2
free_after == free_before - 2
```

现在先填写下面的“实验前预测”，然后才第一次运行红灯。

## 实验前预测

### 1. 对给定输入推演 allocator

这是一张**讲义给定的合成输入**，不是要求猜 QEMU 的真实 map：

| index | base | length | type |
| ---: | ---: | ---: | --- |
| 0 | `0x0000` | `0x2000` | `USABLE` |
| 1 | `0x2000` | `0x3000` | `RESERVED` |
| 2 | `0x8000` | `0x3000` | `USABLE` |

根据正文算法计算：

- `pmm_init()` 后 `free_pages`；
- 第一次和第二次分配返回的 PA；
- 两次分配后的 `free_pages` 与 `allocated_pages`；
- 为什么 PA 0 在这里不是失败。

### 2. 当前红灯输出

根据第 10 节展示的占位代码，写出四个 marker 哪些会出现、哪些不会出现，以及控制流停在哪里。

### 3. 类型策略

回答为什么本课不把 `BOOTLOADER_RECLAIMABLE` 加进 free pool。答案必须指出当前仍放在其中的至少两类活数据。

### 4. 证据边界

如果未来出现 `PMM:OK`，它是否足以证明两页已经清零并安装进新页表？根据 checker 明示的观察量解释。

## 11. 第一次运行：确认红灯

完成预测后运行：

```sh
make check-physical-pages
```

把原始输出复制到 `notes/note-26.md`。预期失败只应位于：

```text
memory map accepted
→ pmm_init() 尚未建立 ownership state
```

若连 `LIMINE:MEMMAP:OK` 都没有，说明失败不属于本课练习，不要用修改 allocator 掩盖它。

## 12. 实验：完成两个函数

编辑 `kernel/pmm.c`，只完成：

```c
bool pmm_init(...);
bool pmm_alloc_page(...);
```

先运行静态观察命令确认 API、状态字段和练习槽位：

```sh
make inspect-physical-pages
```

### 12.1 `pmm_init()` 完成标准

按顺序建立：

1. 拒绝 `allocator == NULL`、`memory_map == NULL`、`entries == NULL` 或空 map；
2. 明确初始化结构体的全部六个字段，不能依赖未初始化 stack bytes；
3. 遍历所有 entries，先检查 entry pointer；
4. 只累计 `entry->type == LIMINE_MEMMAP_USABLE`；
5. 每项页数为 `entry->length / PMM_PAGE_SIZE`；
6. 仅当 `free_pages > 0` 时成功。

### 12.2 `pmm_alloc_page()` 完成标准

按顺序建立：

1. 拒绝无效参数、未初始化 map 或 `free_pages == 0`；
2. 如果 `next_page >= current_range_end`，从 `next_entry_index` 继续扫描；
3. 跳过 `NULL`、非 `USABLE`、不足一页的 entry；
4. 找到 entry 后设置当前 range 的 `next_page` 与 `current_range_end`；
5. 所有 entry 都耗尽时返回 `false`；
6. 成功时先写回当前 PA，再推进 cursor 和两个 counters。

注意更新次序：

```text
*physical_address = next_page
next_page += 4096
free_pages -= 1
allocated_pages += 1
```

如果先推进 `next_page` 再写回，第一帧会被跳过。

### 12.3 分级提示

<details>
<summary>提示 1：初始化循环的判断</summary>

```c
const struct limine_memmap_entry *entry = memory_map->entries[index];
if (entry != NULL && entry->type == LIMINE_MEMMAP_USABLE) {
    /* 累计完整页数 */
}
```

</details>

<details>
<summary>提示 2：为什么分配函数需要两层循环</summary>

外层处理“当前 range 是否耗尽”；内层从 `next_entry_index` 跳过不能分配的 entries，直到找到下一段 `USABLE` 或整个 map 耗尽。

</details>

<details>
<summary>提示 3：找到下一段时设置什么</summary>

```c
allocator->next_page = entry->base;
allocator->current_range_end = entry->base + entry->length;
```

固定版协议已经保证 `USABLE` 两端 4 KiB 对齐。

</details>

## 13. 绿灯取证

实现后运行：

```sh
make check-physical-pages
```

不要把讲义中的合成数值当成 QEMU 的预期地址。真实 `first` 可能是 0，也可能随平台配置变化。应观察的是不变量：

```text
first、second 对齐且不同
free: N → N-2
allocated: 0 → 2
```

再确认上一课没有被破坏：

```sh
make check-limine-handoff
```

把完整输出记录到笔记，并回答观察题。

## 观察题

1. 实验驱动保存的 `free_before`、两个 output PA、输出时的 `free_after` 和 allocator 的 `allocated_pages` 分别是多少？先指出每个值来自局部快照、output parameter 还是 allocator 字段，再抄录真实数值。
2. 为什么第二次分配不能再次返回 `first_page`？请同时指出 cursor 与 counter 的变化，不能只写“因为分配过了”。
3. 两次分配后，原 Limine memory-map entry 为什么仍会写着 `USABLE`？此刻“是否空闲”的权威状态在哪里？
4. 若 `first_page == 0`，为什么它仍可能是一次成功分配？为什么不能据此解引用 `(void *)0`？
5. `PMM:OK` 之后还缺哪些关键步骤，才能把某个 frame 真正用作 kernel-owned page table，并最终让 CPU 使用这套页表？请沿着“获得可访问的 VA → 初始化 frame 内容 → 建立页表结构 → 切换页表根”的顺序回答。

## OS 视角（简要）

xv6 的 `kalloc()` 最终也是在做 physical page ownership 转换，只是 xv6 已经把 free frames 串成 free list，因此支持 `kfree()` 归还。Linux 的 buddy allocator 更复杂，是因为它还要处理连续页、不同 zone、回收与并发。

本课先保留最小状态机，是为了让后面的每次复杂化都有明确需求：需要页复用时再加 free list，需要连续大块时再讨论 buddy，需要多核时再加锁。

## 官方与配套参考

- [固定版本 Limine Boot Protocol：Memory Map Feature](https://github.com/Limine-Bootloader/limine-protocol/blob/4e1587972c148d43b2f397e4e5983bdd6c2a55a0/PROTOCOL.md#memory-map-feature)
- [xv6-riscv `kernel/kalloc.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/kalloc.c)
- [OSTEP：Free-Space Management](https://pages.cs.wisc.edu/~remzi/OSTEP/vm-freespace.pdf)

本课以固定 commit 的 Limine protocol 为合同，因为源码构建也固定在同一 commit；不要用其他版本的模糊印象替代当前 ABI。

## 完成标准

- 能区分 memory map、PMM 与 VMM。
- 能解释 physical frame ownership 为什么需要独立 bookkeeping。
- `pmm_init()` 只接纳 `USABLE` pages，并初始化全部状态。
- `pmm_alloc_page()` 能跨 entries 分配，不重复返回同一 frame。
- 能解释为什么 PA 0 可能有效、为什么 API 不能用 0 表示失败。
- `make check-physical-pages` 与 `make check-limine-handoff` 都通过。
- `notes/note-26.md` 的预测、原始输出和五个观察题完整。
