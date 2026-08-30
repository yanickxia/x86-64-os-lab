# 第 26 课学习记录

日期：2026.08.12

> 先读讲义第 0–10 节并查看 `kernel/pmm.h`、`kernel/pmm.c`，再填写预测。第一次运行 `make check-physical-pages` 前完成；错误预测不要覆盖，实验后在“我的解释”中修正。

## 实验前预测

### 1. 合成 memory map 推演

对讲义给定的三项输入：

- `pmm_init()` 后 `free_pages`：5
- 第一次分配返回：0x0000
- 第二次分配返回：0x1000
- 两次分配后 `free_pages`：3
- 两次分配后 `allocated_pages`：2
- PA 0 是否表示失败，为什么：本课使用 revision 6。因此 QEMU 上 allocator 可能合法返回 PA 0x0。

### 2. 当前红灯

- 一定出现的 marker：
    LIMINE:ENTRY         会出现：已经进入 kernel
    LIMINE:MEMMAP:OK     会出现：第 25 课 handoff 仍成立
    PMM:INIT:FAIL        会出现：pmm_init() 固定返回 false
- 一定不出现的 marker：  PMM:OK               不会出现：代码在第一次分配前已经 halt
- 控制流停在哪里：
  ```
   if (!pmm_init(&allocator, response)) {
        debug_puts("PMM:INIT:FAIL\n");
        halt_forever();
    }
  ```
- 为什么第 25 课成立，本课仍然应当红灯：是2个逻辑，一个是获取内存地图，一个是allocator

### 3. 为什么只接纳 `USABLE`

- `BOOTLOADER_RECLAIMABLE` 当前仍可能保存的两类活数据：response、初始栈和 bootloader 页表仍可能位于其中
- 为什么名字中的 reclaimable 不等于现在就 free：reclaimable 表示：满足释放前置条件后可以回收。还没有满足

### 4. `PMM:OK` 的证据边界

- 它能证明：PMM 已经初始化完成
- 它不能证明页面已经清零并安装进新页表，原因：PMM 只初始化了内存，没有初始化页表

## 红灯

### `make check-physical-pages`

```text
Limine/UEFI host tools check passed
physical-page check: memory map was accepted, but no two pages changed ownership
physical-page check: complete pmm_init() and pmm_alloc_page() in kernel/pmm.c
physical-page output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:INIT:FAIL
make: *** [check-physical-pages] Error 1
```

- 失败准确位于哪一层：pmm_init()

## 我的实现

### `pmm_init()`

- 参数检查：
  if (allocator == NULL || memory_map == NULL || memory_map->entries == NULL || memory_map->entry_count == 0) {
        return false;
    }
- 六个字段的初值：
  allocator->memory_map = memory_map;
    allocator->next_entry_index = 0;
    allocator->next_page = 0;
    allocator->current_range_end = 0;
    allocator->free_pages = 0;
    allocator->allocated_pages = 0;
- 统计 `USABLE` pages 的条件与公式：
  for (uint64_t index = 0; index < memory_map->entry_count; ++index) {
        const struct limine_memmap_entry *entry = memory_map->entries[index];

        if (entry != NULL && entry->type == LIMINE_MEMMAP_USABLE) {
            allocator->free_pages += entry->length / PMM_PAGE_SIZE;
        }
    }

### `pmm_alloc_page()`

- 当前 range 耗尽的判断：allocator->next_page >= allocator->current_range_end
- 如何继续寻找下一段 `USABLE` range：entry != NULL && entry->type == LIMINE_MEMMAP_USABLE && entry->length >= PMM_PAGE_SIZE
- 成功时 output、cursor、free/allocated counters 如何变化：
   *physical_address = allocator->next_page;
    allocator->next_page += PMM_PAGE_SIZE;
    allocator->free_pages--;
    allocator->allocated_pages++;
- 整张 map 耗尽时如何返回：
  return false

## 绿灯原始观察

### `make check-physical-pages`

```text
$ make check-physical-pages
Limine/UEFI host tools check passed
physical-page check passed: two distinct aligned pages moved from free to kernel-owned
physical-page state: first=0x0000000000000000, second=0x0000000000001000, free=0x000000000000cca3->0x000000000000cca1, allocated=0x0000000000000002
```

摘录真实状态：

- `free_before`（第一次分配前从 `allocator.free_pages` 保存的局部快照）：0x000000000000cca3
- `first_page`：0x0000000000000000
- `second_page`：0x0000000000001000
- `free_after`（两次分配后的 `allocator.free_pages`，不是独立字段）：0x000000000000cca1
- `allocated_pages`：0x0000000000000002

### `make check-limine-handoff`

```text
$ make check-limine-handoff
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cca3 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cca1 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK'
```

## 我的解释

### 1. 五个观察量的来源与真实数值

free_before    = 0xcca3
first_page     = 0x0000
second_page    = 0x1000
free_after     = 0xcca1
allocated_pages = 2

free_before     局部快照
first/second    output parameters
free_after      allocator.free_pages
allocated_pages allocator.allocated_pages

### 2. 为什么第二次不会返回同一页
- 因为已经分配了，回去找新的，已经使用的还没有回收机制
- 第一次返回 next_page
→ next_page += 4096
→ free_pages--
→ allocated_pages++
→ 第二次从推进后的 next_page 返回

### 3. 为什么 Limine entry 仍是 `USABLE` 
因为 mmap 的应该不会更新了，allactor 是我们内核的工作，memory map 是不变化的启动快照；当前是否空闲以 allocator 的游标和计数为准。


### 4. 若真实 `first_page == 0`
是可能成功的，为什么不能据此解引用 (void *)0，不能，我们是返回 true or false 来判断的，返回 true 说明 PA 0 分配成功，但 PA 数值不是可解引用的 VA；必须经过 HHDM 或其他映射得到虚拟地址。

### 5. 距离使用 kernel-owned page table 还缺哪些关键步骤
PA + HHDM offset → 可访问 VA
→ 清零 4 KiB frame
→ 填写页表项与权限
→ 保留当前 kernel/stack 必需映射
→ 把新页表根装入 CR3


## 仍然不清楚的问题

- 
