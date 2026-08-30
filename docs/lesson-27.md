# 第 27 课：通过 HHDM 访问并清零物理页

第 26 课结束时，PMM 已经能把一个 4 KiB physical frame 从 `FREE` 转成 `KERNEL-OWNED`，并返回它的物理地址（PA）。但那个 PA 仍只是一个地址数值，C 代码不能把它直接当作指针解引用。

本课补上这条最短路径：

```text
PMM 分配 PA
    → 读取 Limine 返回的 HHDM offset
    → VA = offset + PA
    → C 通过 VA 写入同一个 physical frame
    → 清零完整 4096 bytes
```

完成后，我们仍不会创建页表项，也不会写 `CR3`。本课只证明：kernel 已经能访问并初始化自己拥有的 physical frame。

## 先修知识

只需要带着第 25、26 课的五个结论：

1. Limine feature 使用 request/response；未成功处理的 request 会保留 `response == NULL`。
2. `entry->base` 和 `pmm_alloc_page()` 返回的是 PA 数值，不是 C 指针。
3. 当前 PMM 只从 `LIMINE_MEMMAP_USABLE` 分配，因此返回的 frame 属于 kernel。
4. PA 0 可以合法；成功与否由 `bool` 判断。
5. CPU 当前正在使用 Limine 建立的页表，而不是 kernel-owned page tables。

本课没有新汇编，也不要求记页表项 bit layout。

## 本课只引入一个机制

唯一新增机制是 **HHDM 物理页访问与初始化**：

```c
bool hhdm_prepare_page(uint64_t hhdm_offset,
                       uint64_t physical_address,
                       uint64_t **virtual_page);
```

成功时，它必须同时完成：

1. 用 `hhdm_offset + physical_address` 得到可解引用的 VA；
2. 清零该 VA 指向的完整 4 KiB frame；
3. 通过 output parameter 返回指针。

本课暂不加入：

- PML4、PDPT、PD、PT 的分配与连接；
- page-table entry flags；
- kernel stack 迁移；
- `CR3` 切换与 TLB 处理；
- `free_page()`、bitmap 或 buddy allocator。

把“能够访问 frame”和“把 frame 组织成新页表”拆开，能让每次失败只对应一个机制。

## 1. 为什么 PA 不能直接成为 C 指针

C 指针最终被 CPU 当作**虚拟地址**使用。假设 PMM 返回：

```text
physical_address = 0x0000000000003000
```

下面的写法把数值 `0x3000` 当成 VA，而不是告诉 CPU“访问 PA 0x3000”：

```c
uint64_t *wrong = (uint64_t *)(uintptr_t)physical_address;
wrong[0] = 0;
```

只有当前页表恰好存在 `VA 0x3000 → PA 0x3000` 的 identity mapping 时，它才可能碰巧工作。Limine base revision 6 不提供这种低地址恒等映射合同，因此 kernel 不能依赖它。

第 10 课的自制启动路径确实建立过低 2 MiB identity map，但那是另一张镜像、另一条启动路径。现在的 Limine kernel 不能把旧实验里的页表假设偷偷带过来。

## 2. HHDM 到底是什么

HHDM 是 **Higher Half Direct Map**，可译为“高半直接映射”。三个词分别表示：

- **Higher Half**：这段虚拟地址位于地址空间的高半区域；
- **Direct Map**：被覆盖的 PA 都通过同一个 offset 得到 VA；
- **Map**：它仍然由页表建立，不是绕过分页直接碰物理内存。

核心合同只有一个公式：

```text
VA = HHDM offset + PA
PA = VA - HHDM offset    （只对已知属于 HHDM 的 VA 使用）
```

例如：

```text
offset = 0xffff800000000000
PA     = 0x0000000000003000
VA     = 0xffff800000003000
```

从 CPU 的角度，读写这个 VA 时仍会遍历当前页表；Limine 已经预先建立了：

```text
VA 0xffff800000003000 → PA 0x0000000000003000
```

“direct” 描述的是地址之间存在统一加法关系，不表示没有 MMU、页表或权限检查。

## 3. 为什么操作系统喜欢 direct map

内核经常先从 PMM 得到 PA，然后立刻需要访问 frame 内容：清零用户页、构造页表、读 ACPI 数据或管理页元数据。如果每拿到一个 PA 都先临时寻找空闲 VA、创建映射、使用后再拆映射，基础内存管理会陷入循环依赖。

direct map 提供一条固定规则：

```text
已知 PA ──加统一 offset──> 内核可访问 VA
```

早期小型系统常用 identity mapping，因为 `VA == PA` 最直观；随着内核放到高半、低地址空间留给用户程序，而且机器物理内存变大，内核通常保留一个独立的 physical-memory window。Limine 的 HHDM 就是在 handoff 阶段替我们建立这扇窗口。

这里要分清两段高半映射：

```text
kernel ELF mapping                HHDM mapping
按 ELF PT_LOAD 的 VMA 运行代码     按 offset + PA 访问物理内存
例如 entry 0xffffffff80001000     例如 offset 0xffff800000000000
用途：执行 kernel text/data        用途：访问 physical frames
```

二者都可能在高半，但地址合同和用途不同。不能拿 kernel link base 代替 HHDM offset。

## 4. HHDM offset 从哪里来

与 memory map 一样，kernel 必须显式放置 request：

```c
__attribute__((used, section(".limine_requests")))
static volatile struct limine_hhdm_request hhdm_request = {
    .id = LIMINE_HHDM_REQUEST_ID,
    .revision = 0,
};
```

Limine 成功处理后填写：

```c
struct limine_hhdm_response {
    uint64_t revision;
    uint64_t offset;
};
```

角色边界是：

| 角色 | 本课是谁 | 做什么 |
| --- | --- | --- |
| mapping producer | Limine | 创建初始页表中的 HHDM mappings，并返回 offset |
| PA producer | 第 26 课 PMM | 返回一个 kernel-owned `USABLE` frame |
| mapping consumer | `hhdm_prepare_page()` | 用 response 中的 offset 把 PA 转成 VA |
| page-content owner | kernel | 通过 VA 初始化自己拥有的 frame |
| observer | 实验驱动 + `check-hhdm-page` | 写入非零哨兵，再验证地址关系和完整清零 |

协议明确允许 bootloader 在不同启动中选择不同 HHDM base，甚至随机化。因此禁止写死本机观察到的 `0xffff800000000000`；唯一权威输入是 `hhdm_request.response->offset`。

## 5. HHDM 不是“所有物理地址都一定可访问”

“direct map”很容易让人误以为从 0 到最大物理地址的每个 byte 都被映射。对本课固定的 base revision 6，协议只保证以下 memory-map 类型位于 HHDM：

- `USABLE`；
- `BOOTLOADER_RECLAIMABLE`；
- `EXECUTABLE_AND_MODULES`；
- `FRAMEBUFFER`；
- `RESERVED_MAPPED`；
- `ACPI_RECLAIMABLE`；
- `ACPI_NVS`。

普通 `RESERVED` 与 `BAD_MEMORY` 不在这项保证里。不能拿任意 PA 做加法后就解引用。

本课为什么安全？因为调用链已经建立了更窄的前置条件：

```text
pmm_alloc_page()
  只从 USABLE 返回 PA
  → base revision 6 保证 USABLE 被映射进 HHDM
  → offset + PA 可访问
```

`hhdm_prepare_page()` 自己只收到 offset 和 PA，无法重新证明 PA 来自哪个 memory-map entry；“调用者只传入 HHDM-covered frame”是它的 API 前置条件。

## 6. 这次 C 转换具体做了什么

目标表达式是：

```c
uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);
```

从内到外读：

1. `hhdm_offset + physical_address` 先计算 64-bit VA 数值；
2. `uintptr_t` 是能容纳指针数值的无符号整数类型，明确表达 integer/pointer 边界；
3. `(uint64_t *)` 把 VA 解释为“指向 64-bit words 的指针”；
4. `page[index]` 让 CPU 通过当前页表访问对应 frame。

这不是“把物理内存复制到高半”。两个地址是同一份 physical bytes 的不同名字：

```text
PA 0x3000                描述 frame 的物理位置
VA offset + 0x3000       CPU 当前可解引用的地址
                         ↓ page-table translation
                       同一个 frame
```

这种“多个 VA 指向同一个 PA”的现象叫 **aliasing（别名映射）**。写其中一个 VA，其他指向同一 PA 的映射会观察到相同内存内容；并没有产生第二份页面。

## 7. 三项输入检查不是装饰

### 7.1 output pointer 不能是 `NULL`

函数需要通过 `*virtual_page` 写回结果；若 output pointer 本身为 `NULL`，写回会触发无效内存访问。

### 7.2 PA 必须 4 KiB 对齐

本函数准备的是完整 physical frame，而不是 frame 中间某个地址：

```c
(physical_address & (PMM_PAGE_SIZE - 1)) == 0
```

当 page size 是 4096（`0x1000`）时，低 12 bits 全为 0 才表示 4 KiB 对齐。

### 7.3 加法不能溢出

无符号 64-bit 加法溢出会回绕。应在加法前检查：

```c
physical_address > UINT64_MAX - hhdm_offset
```

若成立，`offset + PA` 已无法在 `uint64_t` 中表达，必须失败，而不是得到一个回绕后的错误 VA。

我们不在 helper 中另写一套 x86 canonical-address 判断：只要 response 来自当前固定协议、PA 属于被覆盖的 range，Limine 已负责建立合法 mapping。本课只处理自己的输入边界。

## 8. 为什么必须清零整页

刚从 PMM 获得 ownership 不代表页面内容为零。它可能保留 firmware、bootloader 或之前使用者留下的 bytes。真实 kernel 把 frame 交给其他 subsystem 前必须按用途初始化，尤其不能把残留数据泄漏给用户态。

下一课准备把 frame 用作页表。x86-64 page-table entry 的 `Present`、权限和 frame address 都编码在 64-bit word 中。若只覆盖准备使用的几项，其余垃圾 word 可能碰巧带有 `Present=1`，CPU 就会把随机地址和权限当成有效映射。

### 8.1 不是 512 页，而是一页中的 512 个 word

这里有四个容易混在一起的单位：

| 名称 | 本课中的含义 | 数量关系 |
| --- | --- | --- |
| physical frame | PMM 分配的一块物理内存 | 当前固定为 4096 bytes |
| virtual page | 虚拟地址空间中一块 4096-byte 区域 | 可通过页表映射到一个 frame |
| `uint64_t` word | C 每次读写的 64-bit 整数 | 8 bytes |
| page-table entry | frame 成为页表后，其中一个 64-bit 表项 | 也是 8 bytes |

所以本课只分配并清零了 **一个 4 KiB physical frame**，不是 512 个 page。因为 `page` 的类型是 `uint64_t *`，C 把这一页内容看成连续的 8-byte 元素：

```text
一个 frame = 4096 bytes
一个 word  = sizeof(uint64_t) = 8 bytes

一个 frame 中的 word 数量
= 4096 bytes / 8 bytes
= 512 words
```

地址布局是：

```text
同一个 4 KiB frame

VA + 0x000   page[0]     8 bytes
VA + 0x008   page[1]     8 bytes
    ...
VA + 0xff8   page[511]   8 bytes
VA + 0x1000  frame 结尾，不属于这一页
```

这里变量名 `page` 表示“指向一页内容的指针”；`page[index]` 表示这页中的第 `index` 个 `uint64_t`，并不表示第 `index` 个 page。

### 8.2 为什么页表恰好也是 512 项

x86-64 的普通 page size 是 4 KiB，硬件又把每个 page-table entry 定义为 64 bits，也就是 8 bytes。因此一个 paging-structure page 恰好容纳：

```text
4096 / 8 = 512 page-table entries
```

512 等于 `2^9`，所以一个虚拟地址在每一级页表中使用 9 bits 选择其中一项。下一课会把这个 frame 正式解释为 512-entry page table；本课清零时它还只是一个 kernel-owned frame，我们只把它当作 512 个普通的 64-bit words。

### 8.3 整套页表不是只有一个页

“一个页表页有 512 项”描述的是**一个树节点的容量**，不是整棵 page-table tree 的大小。x86-64 四级页表中，每个层级的每个节点都单独占一个 4 KiB physical frame：

```text
CR3
 └─ PML4 page（4 KiB，512 项）
     └─ PDPT page（4 KiB，512 项）
         └─ PD page（4 KiB，512 项）
             └─ PT page（4 KiB，512 项）
                 └─ mapped 4 KiB data/code frame
```

若完全从空白页表开始，只映射一个普通 4 KiB virtual page，最少需要为这条路径准备四个 paging-structure pages：PML4、PDPT、PD 和 PT 各一个；被映射的 data/code frame 另算一个页。以后映射更多 VA 时：

- 若新 VA 与已有 VA 共享高层 index，可以复用已有的 PML4/PDPT/PD page；
- 只有走到尚不存在的分支时，才分配新的下级页表页；
- 若使用 2 MiB huge page，PD entry 可以直接成为叶子，不再需要最下层 PT page。

因此页表不是固定只有 4 页：**四级**是一次地址翻译最多经过的层级数，而实际页表页数量会随着映射范围和分支数量增长。

第 27 课仍然只清零一个 frame，因为本课只验证 `PA → HHDM VA → 初始化 contents`。这个 frame 现在甚至还不能称为页表页；等后续课程把它指定为某一级节点、填写合法 entries，并连接到页表树后，它才真正获得 page-table page 的角色。

### 8.4 为什么循环 512 次

因此循环边界应是：

```c
for (size_t index = 0; index < PMM_PAGE_SIZE / sizeof(*page); ++index) {
    page[index] = 0;
}
```

最后一个元素是 `page[511]`，地址为 `VA + 511 * 8 = VA + 0xff8`。写到 `page[512]` 就已经越过本 frame。

## 9. 哨兵、红灯与证据边界

**哨兵值（sentinel）** 是实验仪器事先写入的、容易识别的特殊值。本课 observer 在调用你的函数前，把 512 个 words 全部写成：

```text
0xa5a55a5adeadbeef
```

这样“函数返回后读到 0”才证明发生了清零，不能把 bootloader 恰好给了一页零内存误当成功。

绿灯要求同时成立：

```text
VA == HHDM offset + PA
first word before == sentinel
last word before  == sentinel
first word after  == 0
last word after   == 0
page_is_zero() 扫描 512 words 全部为 0
```

`HHDM:PAGE:OK` 能证明：

- request 得到 response；
- 一个 PMM frame 能通过动态 offset 被访问；
- 返回 VA 满足统一 offset 公式；
- 完整 4096 bytes 已从非零内容变成零。

它不能证明：

- frame 已经成为 PML4 或其他层级；
- 已建立任何新 VA → PA mapping；
- kernel 已切换到自己的 stack/page tables；
- `CR3` 或 TLB 发生了变化。

## 10. 当前红灯为什么会亮（先不要运行）

脚手架已经替你完成协议 boilerplate 和实验仪器：

1. Limine 处理 HHDM request；
2. 第 26 课 PMM 仍分配两个 physical frames；
3. observer 通过 HHDM 把第一个 frame 写满非零 sentinel；
4. 然后调用 `hhdm_prepare_page()`。

当前 `kernel/hhdm.c` 的练习槽固定：

```c
(void)hhdm_offset;
(void)physical_address;
(void)virtual_page;
return false;
```

所以不用运行也能推出控制流：

```text
LIMINE:MEMMAP:OK      出现
PMM:OK                出现
HHDM:RESPONSE:OK      出现
HHDM:PREPARE:FAIL     出现并 halt
HHDM:PAGE:OK          不出现
```

红灯没有要求你猜 QEMU 真实选择的 HHDM offset 或 PA；它只检查从页面展示的控制流就能推出的 marker。

## 实验前预测

先在 `notes/06-Limine与内核主线/note-27.md` 填写，不要运行后覆盖原答案。

### 1. 给定地址计算

对讲义给定的合成输入：

```text
hhdm_offset     = 0xffff800000000000
physical_address = 0x0000000000003000
```

计算：

- `virtual_page` 的 VA；
- 第一个 64-bit word 的 VA；
- 最后一个 word `page[511]` 的 VA；
- 为什么 `page[512]` 不属于这个 frame。

### 2. 三个边界条件

根据第 7 节判断以下调用应成功还是失败，并说明触发哪条检查：

- `physical_address = 0x0`，其他输入合法；
- `physical_address = 0x1234`；
- `hhdm_offset = 0xfffffffffffff000`，`physical_address = 0x2000`。

### 3. 当前红灯输出

根据第 10 节，写出五个 marker 哪些出现、哪些不出现，以及控制流停在哪里。不要填写真实 offset，因为红灯不会打印它。

### 4. 证据边界

未来出现 `HHDM:PAGE:OK` 后，是否已经拥有 kernel-owned page tables？它只新增证明了哪两件事？

## 11. 第一次运行：确认红灯

预测完成后运行：

```sh
make check-hhdm-page
```

预期失败层次是：

```text
memory map accepted
→ PMM ownership transition succeeded
→ HHDM response exists
→ hhdm_prepare_page() 尚未转换和清零
```

若看不到 `PMM:OK` 或 `HHDM:RESPONSE:OK`，说明失败不属于本课练习，不要用改 helper 掩盖前置问题。

## 12. 实验：完成一个函数

先查看固定版 ABI 和本课槽位：

```sh
make inspect-hhdm-page
```

只编辑 `kernel/hhdm.c` 中的：

```c
bool hhdm_prepare_page(...);
```

按以下顺序实现：

1. 检查 `virtual_page != NULL`；
2. 检查 PA 4 KiB 对齐；
3. 在加法前排除 `uint64_t` overflow；
4. 计算 `hhdm_offset + physical_address`，经 `uintptr_t` 转成 `uint64_t *`；
5. 循环清零 512 个 words；
6. 用 `*virtual_page = page` 发布结果并返回 `true`。

不要修改实验驱动里的 sentinel，也不要写死本机的 HHDM offset。

### 分级提示

<details>
<summary>提示 1：三个失败条件</summary>

```c
if (virtual_page == NULL ||
    (physical_address & (PMM_PAGE_SIZE - 1)) != 0 ||
    physical_address > UINT64_MAX - hhdm_offset) {
    return false;
}
```

</details>

<details>
<summary>提示 2：得到可解引用指针</summary>

```c
uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);
```

这里的 offset 来自参数，不是常量。

</details>

<details>
<summary>提示 3：完整清零和写回</summary>

循环上界用 `PMM_PAGE_SIZE / sizeof(*page)`，循环后再执行：

```c
*virtual_page = page;
return true;
```

</details>

## 13. 绿灯取证

实现后运行：

```sh
make check-hhdm-page
make check-physical-pages
make check-limine-handoff
```

真实 offset 和 PA 由本次启动决定，不要求与讲义示例相同。应记录并解释的不变量是：

```text
VA = offset + PA
before first/last = sentinel
after first/last  = 0
完整 512 words    = 0
```

## 观察题

1. 真实运行中的 HHDM offset、PA 和 VA 分别是多少？用十六进制加法验证 `VA = offset + PA`。
2. 为什么合法 `PA == 0` 经 HHDM 后不会变成 C null pointer？结合真实或合成 offset 回答。
3. 为什么 observer 必须先写 sentinel，而不能只检查 helper 返回后是 0？`page_is_zero()` 又比只检查首尾多证明了什么？
4. `uint64_t *page` 中指针加一会跨过多少 bytes？为什么清零循环是 512 次而不是 4096 次？
5. 当前 page 的 ownership、可访问 mapping 和 contents 分别由谁负责？为什么 `HHDM:PAGE:OK` 之后仍不能把它叫作 page table？

## 预测修订怎么写

实验前预测必须保留第一次作答原样，即使后来发现算错也不回头覆盖。在笔记的“绿灯原始观察”之后、“我的解释”之前，使用独立的 `## 预测修订`：

```text
### 对应的预测题

- 原预测：第一次写下的答案
- 真实结果：运行观察或重新计算得到的结果
- 错误原因：混淆了哪个输入、单位、地址层次或控制流
```

若原预测正确，也可以写“原预测与真实结果一致”并简述证据。这个章节负责展示认知变化；“我的解释”则回答本课的观察题和机制边界，二者不互相替代。

## OS 视角（简要）

真实内核也需要“PA 到 kernel VA”的稳定路径。Linux 的 linear/direct mapping、xv6 的 physical-memory mapping 在具体布局上不同，但解决的是同类问题：内核的 allocator 管 PA，C 代码实际解引用 VA。

本课最重要的 OS 结论不是记住某个高半常量，而是把三个状态分开：

```text
ownership：这个 frame 现在归谁？           PMM 回答
mapping：CPU 用哪个 VA 能访问这个 frame？  页表/HHDM 回答
contents：frame 中的 bytes 是否已初始化？  当前 owner 回答
```

下一课才会把已清零的 frame 赋予“页表页”这一具体角色。

## 官方与配套参考

- [固定版本 Limine Boot Protocol：HHDM Feature](https://github.com/Limine-Bootloader/limine-protocol/blob/4e1587972c148d43b2f397e4e5983bdd6c2a55a0/PROTOCOL.md#hhdm-higher-half-direct-map-feature)
- [固定版本 Limine Boot Protocol：Memory Layout at Entry](https://github.com/Limine-Bootloader/limine-protocol/blob/4e1587972c148d43b2f397e4e5983bdd6c2a55a0/PROTOCOL.md#memory-layout-at-entry)
- [C17 `uintptr_t` 定义（cppreference 索引）](https://en.cppreference.com/w/c/types/integer.html)

本课仍以仓库固定 commit 的协议为合同；真实运行中打印出的 offset 只是一次观察，不是 ABI 常量。

## 完成标准

- 能解释 HHDM 的三个词，以及“direct”为什么不等于绕过分页。
- 能区分 kernel ELF mapping 与 HHDM mapping。
- 能说明为什么 `USABLE` frame 在 base revision 6 下可通过 HHDM 访问。
- `hhdm_prepare_page()` 检查参数、对齐和 overflow，不写死 offset。
- 准确清零 512 个 64-bit words，并通过 output parameter 返回 VA。
- `make check-hhdm-page`、`make check-physical-pages` 与 `make check-limine-handoff` 通过。
- `notes/06-Limine与内核主线/note-27.md` 保留实验前预测，
  在“预测修订”中记录认知变化，并完成五个观察题。
