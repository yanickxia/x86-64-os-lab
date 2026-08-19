# 第 32 课：让内核自己找到 leaf PTE

## 先修知识

开始前只需要保留第 29–31 课的四个结论：

1. `CR3` 的 address bits 给出 active PML4 的 **physical address**；C 要通过 HHDM 才能解引用页表页。
2. 4 KiB mapping 依次使用 VA 的 PML4、PDPT、PD、PT 四个 9-bit index。
3. parent entry 保存下一张 table 的 PA 与 flags；leaf PTE 保存最终 frame PA 与 flags。
4. 第 31 课的 handler 能修改一个已知 PTE，但这个 PTE pointer 是实验驱动提前保存的，不是 handler 根据 fault VA 找出来的。

本课不再要求重算四个既有 index，也不新增控制寄存器或汇编。需要回顾 C 指针时，可先看 [Freestanding C 与内核代码参考：output parameter 与二级指针](/reference/c)。

## 本课只引入一个机制

实现一个只读的 **software page-table walker**：给它 page-table root 的 PA、HHDM offset 和任意 VA，它沿已有的四级结构找到对应的 leaf PTE，并把 **PTE 自身的地址**交给 caller。

```c
bool vmm_walk_to_pte(uint64_t root_physical_address,
                     uint64_t hhdm_offset,
                     uint64_t virtual_address,
                     uint64_t **pte);
```

本课的边界很窄：

- 会沿现有 parent entries 查找；
- 会返回 leaf slot 的 C pointer；
- 不分配 page-table frame；
- 不创建或修改 mapping；
- 不加载 `CR3`，也不执行 `INVLPG`。

下一课才把 walker 扩展成“parent 缺失时分配并清零，再发布 entry”的 mapper。

## 1. 为什么 kernel 还要自己 walk

CPU 已经会做 hardware page-table walk，但它的接口是“执行一次取指、load 或 store”。成功时 CPU 得到 physical translation，失败时产生 `#PF`；它不会把“leaf PTE 在内核哪个 C pointer”返回给我们。

kernel 却经常需要直接管理页表：

- `mmap`、heap growth 或 lazy allocation 要找到并填写一个空 PTE；
- `munmap` 要找到并清除已有 PTE；
- fork/copy-on-write 要检查并修改权限位；
- page-fault handler 要判断当前 leaf 是 absent、只读还是已经被别的路径安装。

因此真实 OS 都会有软件 walker。xv6 的 `walk()`、Linux 的分层 page-table helpers，解决的都是同一类问题：**从 address-space root 和 VA 定位管理对象，而不是真的替 CPU 执行那次用户内存访问。**

## 2. 从固定 path 到可复用 API

第 29 课使用：

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

它非常适合第一次构造一条已知路径，但有两个限制：

1. caller 必须事先持有四张 table 的所有 PA 和 C pointer；
2. 它只能描述那条预先安排好的路径，不能从任意 root 和 VA 出发查找。

本课把输入收敛成运行时真正拥有的事实：

```text
root PA + HHDM offset + target VA
```

其余 table pointer 都从 parent entry 逐级推导，不再由 caller 缓存四份答案。

## 3. 一步 walk 实际做什么

先看从 PML4 到 PDPT 的一步：

```text
root PA
  │  HHDM offset + PA
  ▼
PML4 C pointer
  │  [VMM_PML4_INDEX(VA)]
  ▼
PML4E = next table PA | flags
  │  & VMM_PAGE_ADDRESS_MASK
  ▼
PDPT PA
```

C 伪代码是：

```c
uint64_t *table = (uint64_t *)(uintptr_t)(hhdm_offset + root_pa);
uint64_t entry = table[VMM_PML4_INDEX(virtual_address)];

if ((entry & VMM_PAGE_PRESENT) == 0) {
    return false;
}

uint64_t next_table_pa = entry & VMM_PAGE_ADDRESS_MASK;
table = (uint64_t *)(uintptr_t)(hhdm_offset + next_table_pa);
```

之后对 PDPT 和 PD 重复同一种状态转换，只替换 index macro。到达 PT 后，不再把 leaf 当作下一张 table：

```c
*pte = &table[VMM_PT_INDEX(virtual_address)];
return true;
```

注意最后一行发布的是 `uint64_t *`：它指向页表中的一个 64-bit slot。

## 4. 成功找到空 PTE，不等于 mapping 已存在

本课最重要的边界是：

```text
parent path 是否存在？     walker 的成功/失败
leaf PTE 是否 present？    mapping 的存在/缺失
```

这两件事不能合并。第 31 课的两个相邻 VA 共用前三层和同一张 PT：

```text
VA 0x0000123456789000 → PT[0x189] = frame 0 | P | RW
VA 0x000012345678a000 → PT[0x18a] = 0
```

对第二个 VA，walker 能一路到达 PT，所以应该返回 `true`，并把 `&PT[0x18a]` 写入 output parameter；caller 随后读到 `**pte == 0`，才知道 mapping 尚未发布。

若 walker 把 leaf PTE 为 0 也当作失败，mapper 就拿不到应该填写的 slot，demand paging 也无法区分“parent path 已有，只缺 leaf”和“中间 table 根本不存在”。

## 5. PA、HHDM VA 与 PTE pointer 不要混淆

一次 walk 会反复经过三种值：

| 值 | 例子 | 能否被 C 解引用 |
| --- | --- | --- |
| table PA | `entry & VMM_PAGE_ADDRESS_MASK` | 不能直接解引用 |
| table HHDM VA | `hhdm_offset + table_pa` | 可以转成 table pointer |
| leaf PTE pointer | `&pt[index]` | 可以读取或修改这个 entry |

parent entry 中必须继续保存 PA，不能把 HHDM pointer 写回 entry。HHDM 只是当前 kernel address space 为软件提供的访问窗口；MMU 的下一层地址仍按架构格式编码为 physical frame address。

## 6. 为什么要检查 `PRESENT` 与 `PS`

每一级 parent 都必须先证明它确实指向下一张 table：

- `PRESENT=0`：这条 parent path 尚不存在，当前只读 walker 不能继续；
- `PS=1`：该 entry 已经是 large-page leaf，不再指向下一张普通 table。

`PS` 是 Page Size bit，也就是本项目中的 `VMM_PAGE_HUGE`。在 PDPT 中它可表示 1 GiB leaf，在 PD 中可表示 2 MiB leaf。本课 API 明确只定位 4 KiB PTE，因此遇到这些 leaf 就返回 `false`，不偷偷把 physical frame 内容误当作下一张 table。

PML4E 没有 large-page 语义；统一拒绝其 bit 7 也能避免沿 reserved-bit entry 继续走。以后若需要支持 large page，应返回“在哪一级结束、是哪种 leaf”的结构化结果，而不是让这个窄 API 猜测。

## 7. output parameter 的失败合同

函数返回 `bool` 表示 walk 是否成功，`uint64_t **pte` 用来发布找到的 pointer：

```c
uint64_t *leaf = NULL;

if (vmm_walk_to_pte(root_pa, hhdm_offset, address, &leaf)) {
    /* leaf 是 PTE 的地址，*leaf 是 PTE 的当前内容 */
}
```

失败路径必须保持 caller 的 output 不变。实现时只使用局部变量逐级计算，全部验证通过后才执行：

```c
*pte = &table[VMM_PT_INDEX(virtual_address)];
```

这与“最后才发布 mapping”是同一种事务思路：先验证，最后一次性公开结果，避免 caller 在失败后误用半成品。

## 8. 本课的 producer、consumer 与 observer

| 角色 | 本课是谁 | 负责什么 |
| --- | --- | --- |
| producer | 第 29–31 课建立并激活的 page tables | 提供一个 mapped leaf 和一个空 leaf slot |
| consumer | `vmm_walk_to_pte()` | 从 root PA 与 VA 推导 leaf PTE pointer |
| observer | kernel debug output + host pure-C checks | 验证真实 active root 与失败边界 |

runtime observer 会在第 31 课 demand store 之前查两个地址：

```text
mapped VA = 0x0000123456789000
empty VA  = 0x000012345678a000
```

它会证明两个返回 pointer 分别等于同一张 PT 中的 `&pt[0x189]` 与 `&pt[0x18a]`。host pure-C checks 另外覆盖 missing parent、HHDM 加法溢出、1 GiB/2 MiB huge leaf 和“失败时不修改 output”。

这些 observer 是课程测试设施，不是 x86 或 Limine protocol 的标准输出。

## 9. 为什么 mapped PTE 可能从 `0x03` 变成 `0x63`

第 29 课最初写入 frame 0 的 leaf 是：

```text
0x0003 = PRESENT | WRITABLE
```

但 CPU 真正使用 mapping 后，可以按架构规则设置 Accessed 和 Dirty 等状态位，因此 runtime 可能观察到 `0x0063`。它仍指向 PA 0，也仍包含 `PRESENT | WRITABLE`。

所以本课不要求预测 mapped PTE 的全部精确 flags。checker 只验证：

- address bits 仍是预期 frame；
- 必需的 `PRESENT`、`WRITABLE` 仍存在；
- 相邻 empty leaf 在 demand store 前确实为 0。

这也是检查页表时应使用 mask 验证不变量，而不是把硬件允许更新的整条 64-bit word 当常量比较的原因。

## 10. 红灯为什么安全

当前 `vmm_walk_to_pte()` 固定返回 `false`。runtime observer 因而打印：

```text
VMM:WALK:RED
```

但第 31 课仍使用已经保存的 `demand_page.pte` 完成原有 fault recovery，所以旧检查继续通过。新 checker 等到最后的 `PF:DIAG:OK` 后，才单独以缺少 `VMM:WALK:OK` 判定红灯。

因此红灯只表示“新 reusable walker 尚未实现”，不会把它混成 demand paging、IDT 或启动环境故障。

## 实验前预测

第一次运行 `make check-page-table-walk` 前，只回答这一题：

> demand store 尚未执行时，`0x000012345678a000` 的三个 parent entries 都 present，但 `PT[0x18a] == 0`。`vmm_walk_to_pte()` 应返回 `false`，还是返回 `true` 并交出一个 pointer？caller 随后通过这个 pointer 读到的 entry 值是什么？

不需要重算四个 index，不预测 HHDM offset、root PA 或 mapped PTE 的完整 flags。

## 运行红灯

```sh
make check-page-table-walk
```

预期看到：

```text
page-table walk check: reusable walker is incomplete
page-table walk check: complete vmm_walk_to_pte() in kernel/vmm.c
```

查看 API、TODO、runtime observer 和最终 symbol：

```sh
make inspect-page-table-walk
```

## 练习

只修改 `kernel/vmm.c` 中的 `vmm_walk_to_pte()`。实现需要满足：

1. 拒绝 `pte == NULL`、非法或未对齐的 root PA，以及每一次 `hhdm_offset + table_pa` 溢出；
2. 通过 HHDM 把 root PA 转成 PML4 pointer；
3. 在 PML4、PDPT、PD 逐级读取对应 entry，要求 `PRESENT=1` 且不是 huge leaf；
4. 用 `entry & VMM_PAGE_ADDRESS_MASK` 得到下一张 table 的 PA，再通过 HHDM 转成 pointer；
5. 到达 PT 后发布 `&table[VMM_PT_INDEX(virtual_address)]`；不要要求 leaf 自己 present；
6. 所有失败路径返回 `false` 且不修改 caller 的 output。

如果需要提示，按层次展开：

<details>
<summary>提示 1：root 的第一道防线</summary>

可复用第 29 课验证 PA 的写法：

```c
(root_physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0
```

在执行加法前还要检查：

```c
root_physical_address > UINT64_MAX - hhdm_offset
```

</details>

<details>
<summary>提示 2：parent entry 的共同判断</summary>

每一级读取 entry 后都先判断：

```c
(entry & VMM_PAGE_PRESENT) == 0
(entry & VMM_PAGE_HUGE) != 0
```

任一成立就返回 `false`。否则用 address mask 取得 next table PA。

</details>

<details>
<summary>提示 3：何时写 output</summary>

遍历期间只更新局部的 `table`、`entry`、`next_table_pa`。到达 PT 后才执行一次：

```c
*pte = &table[VMM_PT_INDEX(virtual_address)];
return true;
```

</details>

## 绿灯取证

完成后运行：

```sh
make check-page-table-walk
```

最后会看到类似摘要：

```text
page-table walk pure-C checks passed
page-table walk check passed: active root reached both adjacent leaf slots
page-table walk mapped leaf: VA=0x0000123456789000, PTE=...
page-table walk empty leaf: VA=0x000012345678a000, PTE=0x0000000000000000
```

mapped PTE 的完整值可能包含 CPU 更新的 Accessed/Dirty bits，不要求与示例逐字相同。

## 唯一新增的解释题

在 `notes/note-32.md` 用一小段话说明：

> 为什么 API 返回 `uint64_t **pte`，而不是只返回当前 entry 的 `uint64_t` 数值？这对后续 mapper 或 page-fault handler 有什么实际用途？

不要再重复解释四级 index、HHDM 公式或 PTE flags；这些已有历史证据。

## 本课边界与下一步

完成本课后，kernel 已经能从任意 root/VA 查到一条**已经存在 parent path**的 4 KiB leaf slot。但它仍不能：

- 在 PML4E/PDPTE/PDE 缺失时申请新的 table frame；
- 自动清零并连接新 table；
- 检测 leaf 冲突后执行 map/unmap policy；
- 支持 1 GiB/2 MiB huge-page leaf；
- 处理并发修改与跨 CPU TLB shootdown。

下一课会把 PMM、HHDM preparation 与这个 walker 的状态机连起来，得到第一个能复用已有层级、并在必要时补 table 的通用 4 KiB mapper。

## 完成标准

- 保留实验前预测，并在绿灯后填写一行预测修订。
- `make check-page-table-walk` 通过；第 29–31 课检查继续通过。
- 能解释 walker 成功、leaf present 与 mapping 存在是三个不同层次的事实。
- 能说明二级 output pointer 为什么让 caller 获得可修改的 leaf slot。
