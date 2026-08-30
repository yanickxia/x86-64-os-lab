# 第 33 课：建立 4 KiB 映射的完整生命周期

## 先修知识

开始前只保留第 26、27、32 课的三个接口边界：

1. `pmm_alloc_page()` 转移一个 physical frame 的 ownership，返回 PA；它不清零，也不建立 mapping。
2. `hhdm_prepare_page()` 把 kernel-owned PA 转成可解引用的 HHDM pointer，并清零完整 4 KiB。
3. `vmm_walk_to_pte()` 只能沿已经存在的 parent path 找到 leaf slot；任一 parent 缺失时返回 `false`。

如果 PA、HHDM VA、parent entry 与 leaf PTE 又混在一起，先回看[第 31.5 课](/lessons/lesson-31.5)。
本课不再重算四个 9-bit index，也不要求记新的 x86 寄存器。

## 本章建立的完整能力

此前课程采用“一课一个机制”，适合隔离启动故障，却把进入 OS 主线后的完整能力切得过碎。
从本章开始，每章围绕一个可独立使用的 OS 能力，组合 2–4 个强相关机制，
再用一个贯穿实验证明它们如何协作。

本章把第 26–32 课的零件收敛成一段最小 **mapping lifecycle**：

1. **create**：parent 缺失时分配、清零并安全发布 table pages；
2. **reuse**：相邻 VA 已有 parent path 时只填写新 leaf，不重复分配 tables；
3. **unmap**：清除一个 leaf 并返回原 mapping，但不伪装成已经回收 frame；
4. **policy boundary**：由 caller 决定何时 `INVLPG`、何时归还 data/table frames。

创建或复用 mapping 的入口是：

```c
bool vmm_map_page_4k(struct pmm_allocator *allocator,
                     uint64_t root_physical_address,
                     uint64_t hhdm_offset,
                     uint64_t virtual_address,
                     uint64_t physical_address,
                     struct vmm_map_result *result);
```

撤销 leaf mapping 的入口是：

```c
bool vmm_unmap_page_4k(uint64_t root_physical_address,
                       uint64_t hhdm_offset,
                       uint64_t virtual_address,
                       struct vmm_unmap_result *result);
```

给定一个已经存在的 PML4 root、目标 VA 和已经由 caller 持有的 data-frame PA，它会：

- 复用已经存在的 parent tables；
- 在第一个缺失 parent 处，为剩余层级申请 table frames；
- 通过 HHDM 清零新 table pages；
- 填写 leaf PTE；
- 最后发布第一个缺失 parent；
- 返回真实 PTE pointer 和本次新分配的 table 数量。

它不会分配 data frame，不会覆盖已有 leaf，也不负责 `INVLPG`。

unmap 只解除 VA → PA 的翻译关系，返回被移除的 PA 与完整旧 PTE；它暂时不回收 data frame，
也不递归释放已经变空的 PT/PD/PDPT。这些动作需要 PMM `free()` 与 page-table lifetime policy，
不能靠清零一个 PTE 冒充完成。

## 1. 第 32 课为什么还不够

第 32 课的 walker 面对两种地址会得到不同结果：

```text
parent path 已存在，leaf == 0   → 返回 leaf pointer
任一 parent 不存在             → 返回 false
```

第一种情况已经足够让 caller 填写 leaf；第二种情况没有 PT slot 可填，
因为保存这个 slot 的 PT page 自己都不存在。

mapper 的新增职责不是再次计算 index，而是把 `false` 背后的“缺层”变成一条完整路径：

```text
发现第一个 zero parent
        ↓
计算还缺几张 table pages
        ↓
PMM 分配 PA
        ↓
HHDM 转成 pointer 并清零
        ↓
连接 private child path
        ↓
发布第一个 parent 的 PRESENT bit
```

这一步开始接近真实 OS 的 `map` 操作。xv6 的 `walk(..., alloc)` 与 `mappages()`
也把“寻找 PTE”和“必要时创建中间页表”分成类似职责。

## 2. data frame 与 table frames 是两类 ownership

本课 API 同时接触两类 physical frame，但只分配其中一类。

| frame | 谁取得 ownership | mapper 做什么 |
| --- | --- | --- |
| 最终 data frame | caller 在调用前从 PMM 取得 | 把 PA 编码进 leaf PTE |
| PDPT / PD / PT frames | mapper 在发现缺层后从 PMM 取得 | 清零、连接为 page-table pages |

因此不能看到“四级映射”就回答需要四次或五次分配。PML4 root 已经由参数提供；
data frame 也已经由 caller 提供。mapper 只为缺少的 **中间 table pages** 调用 PMM。

## 3. 从哪一级缺失，决定分配几张表

4 KiB path 的三个 parent transitions 是：

```text
PML4E → PDPT
PDPTE → PD
PDE   → PT
```

所以：

| 第一个 zero parent | 仍需创建 | table 分配数 |
| --- | --- | ---: |
| PML4E | PDPT、PD、PT | 3 |
| PDPTE | PD、PT | 2 |
| PDE | PT | 1 |
| 三个 parent 都存在 | 无 | 0 |

这里把“缺失”严格定义为 **entry 整个值为 0**。

- `entry == 0`：课程当前没有其他软件状态，可以安全创建下一层；
- `entry != 0 && PRESENT == 0`：可能编码未来的 swap、guard 或 OS-private 状态，本课拒绝猜测；
- `PS == 1`：当前 entry 已经是 1 GiB 或 2 MiB leaf，不是下一张普通 table，本课拒绝覆盖。

本课发布的是 writable leaf，因此复用的每一级 parent 还必须已经带有 `WRITABLE=1`。
mapper 不会擅自把一个只读 parent 升级为可写，
因为那会同时改变该 parent 覆盖范围内其他 mappings 的有效权限。

## 4. 为什么新 page-table page 必须清零

新 frame 原先可能保存 firmware、bootloader 或其他使用者留下的 bytes。PMM 只转移 ownership，不保证内容为零。

一个 page-table page 有 512 个 64-bit entries。如果只填写目标 index，
其他 511 个垃圾 word 中只要偶然带有 `PRESENT=1`，CPU 就可能把随机 address bits 与权限当成真实 mapping。

因此每张新 table frame 都必须先经过：

```text
table PA
  ↓ hhdm_prepare_page()
HHDM pointer + 4096 bytes 全部为零
```

清零不是美化数据结构，而是在建立 511 条明确的 absent entries。

## 5. `PRESENT` 是发布边界

假设 `PML4[0x25]` 当前为 0，并且需要新建 PDPT、PD、PT。危险顺序是：

```text
先写 PML4E = new_pdpt_pa | PRESENT
再慢慢清零和填写 new PDPT / PD / PT
```

一旦第一步完成，CPU 或另一个执行流就有权沿这个 parent 进入 new PDPT。
若 child pages 仍是垃圾或半成品，硬件能观察到一条不完整路径。

本课采用相反顺序：

```text
1. 分配并清零 PDPT、PD、PT
2. 在 private PDPT 中连接 PD
3. 在 private PD 中连接 PT
4. 在 private PT 中填写 leaf PTE
5. 最后写 PML4E = new_pdpt_pa | PRESENT | WRITABLE
```

第 5 步是 **publication**：此前新子树只有 kernel 手里的 HHDM pointers 能访问；
此后 active page-table root 第一次允许 MMU 进入它。

当前实验是单 CPU，也没有抢占，所以这还不是完整并发算法。
但“先初始化 child，最后发布 parent”仍是必须养成的内核不变量。

## 6. output 结果表达什么

成功时 mapper 返回：

```c
struct vmm_map_result {
    uint64_t *pte;
    uint64_t allocated_table_count;
};
```

- `pte` 指向最终被填写的真实 leaf slot；
- `allocated_table_count` 只统计本次新取得的 table frames，不包含 data frame。

失败时不得修改 caller 的 `result`。这让 caller 不会把半成品 pointer 或尚未完成的计数当作成功证据。

但当前 PMM 没有 `free()`。如果三次 table 分配中的第二次失败，
第一张已经取得 ownership 的 frame 暂时无法归还。实现必须保证尚未发布不完整 parent path；
“回滚已分配 ownership”留到后续 PMM 支持回收后处理。

## 7. 本课的具体机器输入

已有映射使用：

```text
old VA          = 0x0000123456789000
PML4 index      = 0x24
```

第一个新目标只把 PML4 index 加一，低三级 index 保持相同：

```text
new VA          = 0x000012b456789000
PML4 index      = 0x25
PDPT / PD / PT  = 0xd1 / 0xb3 / 0x189
PML4[0x25]      = 0 before mapping
```

脚手架先单独分配并清零 data frame，再调用 mapper。由于 `PML4[0x25] == 0`，
本次 mapper 必须创建 PDPT、PD、PT 三张 table pages。

紧接着，脚手架映射相邻的第二页：

```text
reuse VA        = 0x000012b45678a000
PML4/PDPT/PD    = 与第一张新 mapping 完全相同
PT index        = 0x18a
新增 tables     = 0
```

这一步不只是“再调用一次”。它证明 mapper 能分辨两种状态：第一个地址需要创建 parent path；
相邻地址已经到达同一个 PT，只需占用另一个 leaf slot。随后 unmap 只清除第二个 leaf，
第一条 mapping 和三张 parent tables 必须继续存在。

绿灯 observer 会检查五类证据：

1. PMM 的 `free_pages` 恰好减少 3；
2. result 报告 `allocated_table_count == 3`；
3. 第 32 课 walker 能从 active root 找到 mapper 返回的同一个 PTE pointer；
4. 通过两个 VA 写入不同 marker 后，各自 data frame 的 HHDM alias 读到对应值；
5. unmap 第二页后 leaf 变成 0，但 `free_pages` 不变，第一条 mapping 仍保留。

前三项证明数据结构与 ownership；第四项证明 active MMU 真正消费了新路径；
第五项区分 mapping state 与 frame ownership。

## 8. mapper 为什么不执行 `INVLPG`

mapper 只修改 page-table 数据结构。它不知道 caller 是在：

- 构造尚未 active 的 address space；
- 给当前 active address space 添加 mapping；
- 批量修改多个 pages；
- 准备稍后统一执行 TLB shootdown。

因此 TLB policy 留给 caller。本课 runtime observer 在当前 active root 中发布 mapping 后，
由脚手架调用 `invalidate_page(new_va)`，再进行第一次访问。

这与第 29 课不加载 `CR3`、第 32 课不修改 PTE 是同一种分层：底层 helper 只承诺它真正拥有的职责。

## 9. unmap 为什么不等于 free

一次成功 unmap 至少涉及三个彼此独立的状态：

```text
page table：leaf PTE 从 PRESENT entry 变成 0
TLB：CPU 可能仍缓存旧 translation，需要 caller 失效
PMM：data frame 仍然是 kernel-owned，尚未回到 free pool
```

本章的 `vmm_unmap_page_4k()` 只完成第一行，并把旧 PTE 与 PA 返回给 caller。runtime observer 随后执行 `INVLPG`；
未来拥有 `pmm_free_page()` 后，caller 才能根据用途决定归还 data frame。
三张 parent tables 即使暂时全空也继续存在，
因为安全回收它们需要判断整张表是否为空、处理共享关系并维护 address-space lifetime。

这种分层避免两个危险误解：

- PTE 已清零，不代表 frame 已经无人拥有；
- `free_pages` 未增加，不代表 unmap 失败，它只说明本章没有伪造 PMM 回收。

## 10. 红灯为什么安全

当前 `kernel/vmm_mapper.c` 中的 `vmm_map_page_4k()` 和 `vmm_unmap_page_4k()` 都固定返回 `false`。
第一个 TODO 尚未完成时，observer 会打印：

```text
VMM:MAP4K:RED
```

它不会访问尚未映射的 new VA，而是继续运行第 31 课的 demand recovery 和第 28 课的最终 `#PF` 诊断。
因此红灯只表示 mapper 缺失，不会把错误混成 triple fault、旧 mapping 损坏或异常入口故障。

## 实验前预测

第一次运行 `make check-vmm-mapper` 前，只回答下面两题：

1. root 与两个 data frames 都由 caller 提供。第一次映射遇到 `PML4[0x25] == 0`，第二次映射相邻 VA。
   两次 `allocated_table_count` 分别是多少？新 frames 各充当哪一级？
2. 第二页 unmap 后，它的 leaf、三张 parent tables、data frame ownership 和 `free_pages` 应分别处于什么状态？

不需要预测 PA、`free_pages` 或 marker 的精确数值。

## 运行红灯

```sh
make check-vmm-mapper
```

预期看到：

```text
4 KiB mapping lifecycle check: path creation is incomplete
4 KiB mapper check: complete vmm_map_page_4k() in kernel/vmm_mapper.c
```

完成 create/reuse 后，checker 会进入同一实验的下一阶段；若 unmap 仍是 TODO，会改为提示：

```text
4 KiB mapping lifecycle check: leaf removal is incomplete
4 KiB mapper check: complete vmm_unmap_page_4k() in kernel/vmm_mapper.c
```

这不是另开一个实验，而是同一 lifecycle 的分阶段诊断：先保证 mapping 能建立并复用，再验证撤销边界。

查看 API、TODO 和 runtime observer：

```sh
make inspect-vmm-mapper
```

## 练习

只修改 `kernel/vmm_mapper.c`，分两段完成同一个 lifecycle。

### A. `vmm_map_page_4k()`：create + reuse

按下面状态机实现：

1. 验证所有 pointers、root/data PA 格式以及 VA 4 KiB 对齐；失败时不修改 `result`。
2. 通过 HHDM 访问 root，沿 PML4E、PDPTE、PDE 查找第一个 zero parent。
3. 已存在的 parent 必须 `PRESENT=1`、`PS=0`，并检查下一次 HHDM 加法不会溢出。
4. 若三个 parent 都存在，要求 leaf word 为 0，填写 leaf，报告分配 0 张 table。
5. 若发现 zero parent，按表格计算还缺 1、2 或 3 张 tables；先全部分配并清零。
6. 在尚未发布的 child pages 中连接剩余 parent entries并填写 leaf。
7. 最后写入第一个 zero parent，并在成功后一次性发布 `result`。

父级与 leaf 使用本课统一 flags：

```c
VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE
```

### B. `vmm_unmap_page_4k()`：remove leaf

1. 验证 result、root PA 和 page-aligned VA，失败时不修改 `result`。
2. 复用 `vmm_walk_to_pte()` 找到 leaf pointer；parent 缺失或 leaf 非 `PRESENT` 时失败。
3. 先保存完整 old PTE，并用 `VMM_PAGE_ADDRESS_MASK` 提取 data-frame PA。
4. 只把 leaf 写成 0；不要改 parent entries，不调用 PMM，也不执行 `INVLPG`。
5. leaf 清除成功后，最后一次性发布 `physical_address` 和 `old_pte`。

如果需要提示，按层次展开：

<details>
<summary>提示 1：怎样保存“第一个缺失 parent”</summary>

遍历时可保留一个 `uint64_t *missing_entry`，它指向现有 table 中那个值为 0 的 parent slot。
只在所有新 child pages 准备完成后写 `*missing_entry`。

</details>

<details>
<summary>提示 2：怎样组织最多三张新 table</summary>

可以使用两个长度为 3 的局部数组：一个保存 table PAs，一个保存清零后的 HHDM pointers。
`missing_level` 决定实际需要使用几项。

</details>

<details>
<summary>提示 3：怎样决定新 child 中使用哪个 index</summary>

若缺 PML4E，新建 PDPT 使用 `VMM_PDPT_INDEX(va)`，新建 PD 使用 `VMM_PD_INDEX(va)`，
新建 PT 使用 `VMM_PT_INDEX(va)`。若从 PDPTE 或 PDE 才开始缺失，就从对应的剩余 index 开始。

</details>

<details>
<summary>提示 4：unmap 为什么返回完整 old PTE</summary>

真实访问后 CPU 可能已经写入 Accessed/Dirty bits。返回完整 old PTE 让上层保留全部旧状态；
同时返回 mask 后的 PA，避免 caller 把 flags 当成 physical-address bits。

</details>

## 绿灯取证

完成后再次运行：

```sh
make check-vmm-mapper
```

最后会看到类似：

```text
vmm mapper pure-C checks passed
4 KiB mapping lifecycle check passed: create, reuse, and unmap agree
4 KiB mapper mapping: VA=..., PA=..., PTE=...
4 KiB mapper ownership: table pages=0x3, free=...->...
4 KiB mapper reuse: VA=..., PA=..., table pages=0x0
4 KiB mapper unmap: old PTE=..., leaf after=0x0, free unchanged=...
```

observer 真正通过 new VA 写入以后，CPU 可以把 Accessed/Dirty bits 写回 leaf，
因此摘要中的完整 PTE 可能是 `...6063` 而不是最初发布的 `...6003`。
checker 只比较 target PA 与必需的 `PRESENT|WRITABLE`。

纯 C checks 还会验证：已有 parent path 分配 0 张、只缺 PT 时分配 1 张、
occupied leaf、huge leaf 与只读 parent 被拒绝、分配中途失败不会发布不完整 parent；
unmap 还会覆盖成功移除、重复移除、非法输入和 output 不变合同。

## 两个解释题

在 `notes/06-Limine与内核主线/note-33.md` 分别用一小段话说明：

1. 为什么必须先清零并连接全部 child tables，最后才把第一个缺失 parent 写成 `PRESENT=1`？
   如果顺序反过来，CPU 可能观察到什么？
2. 为什么 unmap 后 checker 要求 leaf 为 0，却要求 `free_pages` 保持不变？
   为什么 `INVLPG` 属于 caller 而不是 helper？

不用重复解释四级 index、HHDM 公式或 `uint64_t **`。

## 本课边界与下一步

完成本章后，kernel 拥有 create、reuse、unmap 三段最小 4 KiB mapping lifecycle，但仍然没有：

- physical-frame free API；
- page-table page 的引用计数和空表回收；
- user/supervisor、NX、global 等正式权限 policy；
- 多 CPU page-table lock 与 TLB shootdown；
- 每个 process 独立 address space。

下一章会把 user/supervisor、writable、NX、guard page 与 fault evidence 合成“权限和隔离”；
再下一章处理 address-space ownership、共享 kernel region 与销毁回收。

## 完成标准

- 保留实验前预测，并在绿灯后写预测修订。
- `make check-vmm-mapper` 通过，第 29–32 课检查继续通过。
- 能区分 caller 提供的 data frame、mapper 分配的 table frames 与 unmap 后仍未释放的 ownership。
- 能解释“初始化 child → 最后发布 PRESENT parent”这一核心不变量。
- 能解释 leaf、TLB 与 PMM 是三个不同状态，unmap 不能同时假装完成全部回收。
