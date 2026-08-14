# 第 30 课：切换到 kernel-owned PML4

第 29 课已经在 PA `0x1000..0x4000` 中建立了一条新路径：

```text
VA 0x0000123456789000
  → PML4[0x24]
  → PDPT[0xd1]
  → PD[0xb3]
  → PT[0x189]
  → PA 0
```

但当时 active `CR3` 仍指向 Limine 准备的根表。那条 mapping 只是内存中的数据，CPU 还不会使用它。

本课完成这个状态转换：保留当前执行依赖的映射，把 `CR3` 切到 kernel-owned PML4，再让 CPU 通过新 VA 和 HHDM 两条路径访问同一个 physical frame。

```text
第 29 课：new root exists, active CR3 unchanged
第 30 课：preserve live mappings → load CR3 → execute and access through new root
```

## 先修知识

开始前只需掌握：

1. `CR3` 的 address field 是 CPU 当前 page-table root 的 PA；
2. PML4 entry 指向下一层 PDPT，一项可以代表一整棵下级 subtree；
3. 当前 kernel code/data 位于 `0xffffffff80000000` 附近；
4. HHDM 从 `0xffff800000000000` 开始；
5. 当前 Limine stack 位于 HHDM 覆盖的地址中，精确 `RSP` 是运行时输入；
6. 第 29 课的 custom path 占用新 PML4 的 index `0x24`；
7. 第 28 课的 `#PF` handler 是切换后的故障安全网。

本课没有新的 C 语法；循环、数组、pointer validation 可回到 [Freestanding C 与内核代码参考](reference/c-basics.md) 查询。

## 本课只引入一个机制

先用一句不带术语的话概括：

> 新页表里目前只有第 29 课添加的一条 mapping，不能直接启用；必须先把当前正在使用的映射“借过来”，否则切换 `CR3` 后，kernel 会立刻失去自己的 code 和 stack。

### 先把两张 PML4 分开

当前同时存在两张根页表。

第一张由 Limine 建立，`CR3` 正指向它，所以它是 **active PML4**：

```text
旧 PML4（Limine 提供，CPU 当前使用）
├─ [0x100] → HHDM 与当前 stack 等映射
├─ [0x1ff] → kernel code/data/IDT 等映射
└─ 其他 Limine 建立的映射
```

第二张位于 PA `0x1000`，属于 kernel，但尚未 active。第 29 课只在里面建立了一条 custom path：

```text
新 PML4（kernel-owned，CPU 尚未使用）
└─ [0x024] → PDPT → PD → PT → PA 0
               对应 VA 0x0000123456789000
```

若现在直接执行 `write_cr3(0x1000)`，CPU 会开始使用几乎为空的新 PML4。新表中没有当前 kernel、stack 和 HHDM 的入口，因此可能连 `MOV CR3` 后的下一条指令都无法取得。

### 本课要形成的结果

本课先把旧 PML4 的 entries 复制到新 PML4，但跳过 `0x24`：

```text
新 PML4（复制完成后）
├─ [0x024] → 保留第 29 课的 custom path
├─ [0x100] → 借用 Limine 的 HHDM/stack subtree
├─ [0x1ff] → 借用 Limine 的 kernel subtree
└─ 其他 entries → 复制旧 PML4 的原值
```

这样加载新 `CR3` 后会同时拥有两类映射：

```text
新加入的能力：custom VA → PA 0
继续存活的能力：kernel code、stack、HHDM、IDT 等旧映射
```

这里的“保留”非常具体。第 29 课已经写入：

```text
new_pml4[0x24] = 0x2003
```

如果连 index `0x24` 也从旧 PML4 复制，旧值可能是 `0`，就会把这条 custom path 擦掉。因此不是无条件复制 512 项，而是复制其余 511 项。

### 你实现的函数中，三个参数分别是谁

唯一由你实现的新机制是：**把 active PML4 的 entries 浅拷贝到新 PML4，同时保留新根中已经属于 custom path 的一个 entry**。

```c
bool vmm_clone_root_preserving_entry(uint64_t *destination,
                                     const uint64_t *source,
                                     uint64_t preserved_index);
```

| 参数 | 本课中的具体对象 |
| --- | --- |
| `destination` | 新 kernel-owned PML4 的 HHDM pointer |
| `source` | `CR3` 当前指向的旧 PML4 的 HHDM pointer |
| `preserved_index` | 不允许被覆盖的 custom index，本课是 `0x24` |

函数本质上只做：

```text
检查三个参数
→ 遍历 0..511
→ index == 0x24 时不写 destination
→ 其他 511 项执行 destination[index] = source[index]
→ 返回成功
```

加载 `CR3` 的 x86 inline assembly 已由脚手架提供；你不需要再记一遍 control-register 指令。你的函数只负责准备新 PML4 的内容，不负责激活它。

### 本段术语速查

| 术语 | 在本课中的意思 |
| --- | --- |
| active PML4 | `CR3` 当前选择、CPU 正在使用的旧根页表 |
| new PML4 | PA `0x1000` 的 kernel-owned 根页表 |
| custom path | 第 29 课建立的 `VA 0x0000123456789000 → PA 0` 路径 |
| entry | PML4 中一个 64-bit 项，通常指向一张 PDPT |
| shallow copy | 只复制 entry，两个 roots 仍指向同一批下级 tables |
| bootstrap address space | 足以让 kernel 完成第一次接管的临时过渡地址空间 |

下面这些名词**不是本课先修知识，也不会出现在必答题中**。它们只是说明当前实现的边界，可以先略过：

<details>
<summary>本课暂时不做的后续能力</summary>

- 深拷贝 Limine 的所有 PDPT/PD/PT；
- 回收 bootloader-owned page-table frames；
- 通用的 map/unmap/page-table walker；
- 每个 process 一个 address space；
- PCID、global page 或精细 TLB shootdown；
- kernel/user permissions、NX 和 W^X policy。

</details>

本课得到的是一个可运行的 **bootstrap address space**，不是最终完全独立的地址空间。

## 1. `CR3` 切换不是“换一个变量”

第 29 课中有两个不同状态：

```text
kernel_path.pml4_pa = 0x1000       kernel-owned root 的 PA
read_cr3()          = 另一数值      CPU 仍使用 Limine root
```

C 可以通过 HHDM 填写 PA `0x1000` 的内容，但只有执行 `MOV CR3, ...` 后，MMU 才会从这个 PA 开始之后的 page walk。

这条指令之后，CPU 取下一条 instruction、读下一条字符串、压下一次 stack frame、进入下一次 exception，都要受新页表约束。因此“target path 正确”远远不够；至少以下 live state 必须仍可达：

| live state | 消失后的直接后果 |
| --- | --- |
| 当前 code / `RIP` | `MOV CR3` 后下一条取指就 `#PF` |
| 当前 stack / `RSP` | 函数调用、局部变量或异常压栈失败 |
| kernel data/rodata | IDT、protocol response、字符串等不可读 |
| HHDM | kernel 无法继续通过 PA 操作 page-table frames |
| IDT 与 `#PF` entry | 页表错误无法诊断，可能升级为 double/triple fault |

这正是第 29 课不急着加载 `CR3` 的原因。

## 2. “鸡生蛋”问题：新页表怎样保住正在运行的自己

理想的最终状态是 kernel 逐页建立所有映射，并拥有每一级 table frame。但在第一次切换时，kernel 正站在 Limine 提供的地板上：

```text
Limine root
  ├─ maps kernel image
  ├─ maps boot stack
  ├─ maps HHDM
  └─ maps protocol objects
```

若立即切到只有 custom path 的全新 PML4，新的地板还没覆盖当前 `RIP` 和 `RSP`，CPU 会在切换点坠落。

常见的 bootstrap 方法是分阶段接管：

1. kernel 拥有一张新 root page；
2. 暂时让新 root 借用 bootloader 已有的下级 subtrees；
3. 加入 kernel 自己的新 mapping；
4. 切换 `CR3`；
5. 后续再逐步用 kernel-owned subtrees 替换借用部分。

本课做第 2–4 步。

## 3. 为什么复制一个 PML4E 能保住一大片映射

一个 PML4 entry 不是某个 4 KiB data page 的直接副本。它保存一个 PDPT frame 的 PA；这个 PDPT 又继续指向 PD、PT 和最终 frames。

```text
old PML4E ─┐
           ├──→ same PDPT → same PD → same PT/data mappings
new PML4E ─┘
```

因此把一个 64-bit PML4E 原样复制到新 root，相当于让两个 roots **共享同一棵下级 subtree**。在 4 KiB pages 的完整四级结构中，一个 PML4 slot 最多覆盖 `512 GiB` VA range：

```text
512 PDPT entries × 512 PD entries × 512 PT entries × 4 KiB
= 512 GiB
```

这叫 **shallow copy（浅拷贝）**：只复制 root entry，不复制它指向的对象。它的优点是第一次切换简单可靠；代价是下级 tables 的 ownership 仍属于 Limine/boot environment，kernel 暂时不能回收或随意重建它们。

不要把 `VMM:ACTIVATE:OK` 解释成“所有页表都已经 kernel-owned”。本课只有 custom path 的四张 table pages 属于 kernel，其中 PML4 同时是新 root；从 old root 复制来的 entries 仍指向 borrowed subtrees。

## 4. 当前三个公开的 PML4 indices

PML4 index 仍使用第 29 课的公式：

```c
#define VMM_PML4_INDEX(address) (((address) >> 39) & UINT64_C(0x1ff))
```

本课给出三个可在实验前计算的 VA：

| 角色 | VA | PML4 index |
| --- | ---: | ---: |
| custom target | `0x0000123456789000` | 待计算 |
| HHDM base | `0xffff800000000000` | 待计算 |
| kernel entry 附近 | `0xffffffff80001000` | 待计算 |

stack 的精确 VA 由 Limine 当前运行决定，所以不要求实验前猜数值。脚手架会在实际运行时读取 `RSP` 并计算 index；它通常落在 HHDM subtree 中，但 checker 不写死它必须等于某一个常量。

## 5. 为什么必须跳过 custom slot

第 29 课已经在 destination PML4 写入：

```text
destination[0x24] = PDPT PA 0x2000 | flags 0x3 = 0x2003
```

如果本课直接复制全部 512 entries：

```c
destination[index] = source[index];
```

那么 `source[0x24]` 也会覆盖 destination 的 custom path。旧 root 没有义务在这个地址拥有同样 mapping；常见结果是把 `0x2003` 覆盖成 non-present `0`。

因此合同不是普通 `memcpy()`，而是：

```text
index == preserved_index    保留 destination 原值
其他 511 个 indices         复制 source 原值
```

这也是函数名中 `preserving_entry` 的含义。它是本次 bootstrap 的冲突规则，不是通用 address-space merge policy。

## 6. source 与 destination 分别是谁

`CR3` 给出 active root PA，C 仍需通过 HHDM 才能读取它：

```text
old_root_pa = read_cr3() & VMM_PAGE_ADDRESS_MASK
source VA   = hhdm_offset + old_root_pa
destination = kernel_path.pml4       // 同样是 HHDM pointer
```

两个参数都是 C 可解引用的 VA pointers；复制到 entry 中的 64-bit 值则仍是 table PA + flags。

函数拒绝以下输入：

- `destination == NULL`；
- `source == NULL`；
- `destination == source`，因为这不是一次接管；
- `preserved_index >= 512`，因为会超出一张 PML4。

它不读取 `CR3`、不计算 HHDM pointer，也不激活新 root。调用者已经把这些架构和生命周期信息准备好，使你的练习保持为一个可单测的 C 函数。

## 7. `MOV CR3`、TLB 与切换边界

脚手架提供：

```c
static void write_cr3(uint64_t value) {
    __asm__ volatile("mov %0, %%cr3" : : "r"(value) : "memory");
}
```

在本课未启用 PCID 的范围内，加载 `CR3` 会选择新 translation root，并使旧的 non-global TLB translations 不再被继续当作当前地址空间的缓存结果。于是切换后的成功不能来自“TLB 碰巧还记得旧地址”；新 root 必须真的能翻译后续访问。

这里的 `"memory"` 是 compiler barrier，阻止编译器把相关内存操作随意搬过切换边界；真正改变 MMU 状态的是 `MOV CR3` 本身。

本课不要求手写这段 asm。你需要理解它前后的状态：

```text
before: read_cr3() address field != 0x1000
write:  write_cr3(0x1000)
after:  read_cr3() address field == 0x1000
```

## 8. alias 证据为什么比 marker 更强

切换成功后，脚手架执行：

```text
write marker through custom VA 0x0000123456789000
read the same frame through HHDM VA
```

两次都观察到：

```text
0x30c0ffee30c0ffee
```

它同时证明：

1. custom path 在新 root 下可用；
2. HHDM borrowed subtree 仍可用；
3. 两个 VA 最终 alias 同一个 PA 0 frame；
4. mapping 是 writable，而不只是 page walk 能读到 leaf。

切换前不能先读 custom VA，因为 active root 尚未包含这条 mapping。切换前的初始 `0` 必须通过已经有效的 HHDM alias 观察；否则实验会在 `MOV CR3` 之前就触发 `#PF`，根本没有测试到切换。

## 9. 切换后为什么还故意触发一次 `#PF`

`VMM:ACTIVATE:OK` 后继续访问固定未映射地址 `0x0000400000000000`。若仍出现第 28 课的：

```text
PF:DIAG:OK
```

则说明新 root 下至少还能完成：

```text
faulting instruction
→ IDT lookup
→ assembly entry
→ exception stack use
→ C handler code/data
→ debug output
```

这不是重复考 error-code bits；它把旧课证据用作本课切换后的 safety invariant。

## 10. 红灯成因：先读代码，不要运行

`kernel/vmm.c` 当前故意留下：

```c
bool vmm_clone_root_preserving_entry(/* ... */) {
    (void)destination;
    (void)source;
    (void)preserved_index;
    return false;
}
```

因此可从源码直接推出：

```text
VMM:BUILD:OK
→ clone helper returns false
→ VMM:CLONE:FAIL
→ 不执行 write_cr3()
→ 仍在 old root 下触发固定 #PF
→ PF:DIAG:OK
```

红灯不是“机器切换后崩溃”，而是切换前的 C helper 尚未实现。这样失败不会污染第 29 课或第 28 课的证据。

## 实验前预测

先把答案写进 `notes/note-30.md`，错误预测不要覆盖。

### 1. 三个 PML4 indices

用 `((VA >> 39) & 0x1ff)` 计算：

- custom target `0x0000123456789000`；
- HHDM base `0xffff800000000000`；
- kernel VA `0xffffffff80001000`。

写出三个结果即可；本课不再重复计算 PDPT/PD/PT indices。

### 2. preserved slot

已知 `destination[custom_index] = 0x2003`。循环对其他 indices 执行 `destination[i] = source[i]`，但跳过 `custom_index`：

- clone 后 custom entry 是多少？
- kernel/HHDM/stack 为什么可以继续沿 old subtrees 翻译？

### 3. 当前红灯控制流

根据上一节给出的源码与 marker chain，写出：

- 一定出现的 `VMM:*` markers；
- 一定不出现的 activation marker；
- 为什么 `PF:DIAG:OK` 仍会出现。

不预测 old `CR3`、精确 `RSP` 或 PML4E 的物理值；这些是运行时观察，不是页面给出的输入。

## 11. 运行红灯

完成预测后运行：

```sh
make inspect-kernel-address-space
make check-kernel-address-space
```

预期失败应明确指向：

```text
kernel-address-space check: the active root mappings were not copied into the new root
kernel-address-space check: complete vmm_clone_root_preserving_entry() in kernel/vmm.c
```

若看不到 `VMM:BUILD:OK` 或 `PF:DIAG:OK`，先停止修改，本课前置状态已经损坏。

把完整红灯输出保留到笔记。

## 12. 实验：完成 root clone

只编辑 `kernel/vmm.c` 中的 `vmm_clone_root_preserving_entry()`。

实现顺序：

1. validation；
2. 遍历 `0..VMM_ENTRY_COUNT - 1`；
3. 遇到 `preserved_index` 跳过；
4. 其他 entries 从 source 复制到 destination；
5. 返回 `true`。

### 分级提示

<details>
<summary>提示 1：validation</summary>

```c
if (destination == NULL || source == NULL ||
    destination == source || preserved_index >= VMM_ENTRY_COUNT) {
    return false;
}
```

</details>

<details>
<summary>提示 2：循环边界</summary>

一张 PML4 恰好有 `VMM_ENTRY_COUNT == 512` 个 `uint64_t` entries：

```c
for (uint64_t index = 0; index < VMM_ENTRY_COUNT; ++index) {
    /* ... */
}
```

最后一个合法元素是 `511`，不要写 `<= VMM_ENTRY_COUNT`。

</details>

<details>
<summary>提示 3：保留而不是事后恢复</summary>

```c
if (index != preserved_index) {
    destination[index] = source[index];
}
```

不需要另外保存 `destination[preserved_index]`；直接不写它即可。

</details>

不要编辑 `write_cr3()`、marker 或 checker 来制造绿灯。

## 13. 绿灯取证

实现后运行：

```sh
make check-kernel-address-space
make check-kernel-page-table
make check-page-fault
make check-hhdm-page
make check-physical-pages
make check-limine-handoff
```

固定输入下，关键证据应包含：

```text
old CR3 address field != 0x1000
new CR3 address field == 0x1000
custom/kernel/HHDM indices == 0x24/0x1ff/0x100
target VA and HHDM both observe 0x30c0ffee30c0ffee
VMM:ACTIVATE:OK
PF:DIAG:OK
```

old `CR3`、精确 stack VA 和 copied PML4E 的 PA 部分由 Limine/QEMU 本次运行决定，只记录真实输出，不和讲义中的某次示例硬对齐。

checker 还会在 host 上直接调用同一个纯 C helper，验证：

- valid clone 复制 511 entries 并保留一项；
- `NULL` source/destination 被拒绝；
- in-place clone 被拒绝；
- index `512` 被拒绝。

## 预测修订

在 `notes/note-30.md` 中逐项写：

```text
原预测 → 真实结果 → 错误原因或一致证据
```

只修订三项预测，不重新回答第 29 课的四级 index/entry 计算。

## 唯一新增的解释题

为什么复制 PML4 entries 后，kernel code、stack 和 HHDM 可以继续工作，但还不能宣称这些下级 page tables 已经属于 kernel？这对后续回收 bootloader memory 有什么约束？

回答重点是 shallow copy 与 ownership，不需要再次抄 old/new `CR3` 数值。

## OS 视角（简要）

本课形成了第一个由 kernel 选择 root 的 address space，但它仍是 bootstrap hybrid：

```text
kernel-owned PML4
  ├─ kernel-owned custom subtree
  └─ borrowed Limine subtrees for live mappings
```

下一阶段会把“固定四张新表”和“复制现有 root”收敛成可复用的 page-table walk/map API，并逐步明确哪些 mappings/tables 可以替换或回收。用户进程的独立地址空间、权限与生命周期会在这套 kernel VMM 基础稳定后再进入。

## 官方与配套参考

- [Intel 64 and IA-32 SDM](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)（Volume 3A：4-Level Paging、CR3 与 TLB）
- [AMD64 Architecture Programmer's Manual Volume 2](https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2)（Long-Mode Page Translation、CR3）
- [xv6 book 2025](https://pdos.csail.mit.edu/6.1810/2025/xv6/book-riscv-rev5.pdf)（Chapter 3：每个 page table root 代表一个 address space；架构层数不同，root/subtree ownership 问题相同）
- [MIT 6.1810 page-table lab](https://pdos.csail.mit.edu/6.1810/2025/labs/pgtbl.html)（page-table walk 与 mapping 观察方法）

## 完成标准

- 能区分“新 root 已存在”和“CPU 已加载新 root”；
- 能解释浅拷贝一个 PML4E 为什么共享整棵下级 subtree；
- 能解释为什么必须保留 custom index `0x24`；
- `CR3` 切换后 code/stack/HHDM/custom mapping/`#PF` 均有机器证据；
- 能指出 root ownership 与 borrowed lower-table ownership 的差异；
- `make check-kernel-address-space` 与五项历史回归通过；
- 笔记保留原预测、红灯、实现、绿灯、预测修订和唯一解释题。
