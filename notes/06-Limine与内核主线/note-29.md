# 第 29 课学习记录

日期：2026.08.14

> 第一次运行 `make check-kernel-page-table` 前完成“实验前预测”。错误答案保留；绿灯后只修订不一致之处，不重复抄写已经正确的计算。

## 实验前预测

### 1. 四个 indices

- PML4 index：0x24
- PDPT index：0xd1
- PD index：0xb3
- PT index：0x189
- 计算过程：
```
>>> hex((0x0000123456789000 >> 39) & 0x1ff)
'0x24'
>>> hex((0x0000123456789000 >> 30) & 0x1ff)
'0xd1'
>>> hex((0x0000123456789000 >> 21) & 0x1ff)
'0xb3'
>>> hex((0x0000123456789000 >> 12) & 0x1ff)
'0x189'
```

### 2. 四个 entries

- PML4E：0x2003
- PDPTE：0x3003
- PDE：0x4003
- PTE：0x0003
- target PA 为 0 时 PTE 为什么不是空 entry：当前固定 QEMU memory map 的第一个可分配 frame 是 PA 0x0

### 3. PA 与 HHDM pointer

- C 写 PDPT 使用的 VA：0xffff800000000000
- PML4E address field：0x2000
- 两者为什么不同： page walk 从 CR3 给出的物理根地址开始；MMU 读取 parent entry 后需要下一层的物理 frame 编号。HHDM 是当前地址空间给软件提供的 mapping，不是 page-table entry 的替代编码。


### 4. 当前红灯与旧课证据

- `VMM:FRAMES:OK`：存在
- `VMM:LINK:FAIL`：存在
- `VMM:BUILD:OK`：存在
- `PF:DIAG:OK`：存在
- 本课红灯为什么不破坏第 28 课绿灯：因为这是后续的缺页操作

## 红灯

### `make check-kernel-page-table`

```text
Limine/UEFI host tools check passed
kernel-page-table check: table frames exist, but the four-level path is not linked
kernel-page-table check: complete vmm_map_single_4k() in kernel/vmm.c
kernel-page-table output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc99 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc97 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:LINK:FAIL | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff80001845 | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK
make: *** [check-kernel-page-table] Error 1
```

- 失败准确位于哪一层：
table frames 已分配并清零
→ vmm_map_single_4k() 固定返回 false
→ VMM:LINK:FAIL

## 我的实现

### validation

- pointer validation： path == NULL || path->pml4 == NULL || path->pt == NULL || path->pd == NULL || path->pdpt == NULL
- PA/VA alignment 与 address bits：四个 table PA 与 target PA 都必须落在 `VMM_PAGE_ADDRESS_MASK` 中；target VA 的低 12 bits 必须为 0。PA 0 合法，不能作为失败值。

### 四层 entry

- PML4E： path->pml4[VMM_PML4_INDEX(virtual_address)] = path->pdpt_pa | flags;
- PDPTE： path->pdpt[VMM_PDPT_INDEX(virtual_address)] = path->pd_pa | flags;
- PDE：path->pd[VMM_PD_INDEX(virtual_address)] = path->pt_pa | flags;
- PTE：path->pt[VMM_PT_INDEX(virtual_address)] = physical_address | flags;

## 绿灯原始观察

### `make check-kernel-page-table`

```text
Limine/UEFI host tools check passed
kernel-page-table check passed: four kernel-owned frames form one inactive 4 KiB mapping
kernel-page-table path: VA=0x0000123456789000 -> PA=0x0000000000000000, indices=0x0000000000000024/0x00000000000000d1/0x00000000000000b3/0x0000000000000189
kernel-page-table entries: 0x0000000000002003 -> 0x0000000000003003 -> 0x0000000000004003 -> 0x0000000000000003; active CR3=0x000000000fe07000
```

- 四个 table PA：0x1000 / 0x2000 / 0x3000 / 0x4000
- target VA/PA： VA=0x0000123456789000 -> PA=0x0000000000000000
- 四个 indices：0x0000000000000024/0x00000000000000d1/0x00000000000000b3/0x0000000000000189
- 四个 entries：0x0000000000002003 -> 0x0000000000003003 -> 0x0000000000004003 -> 0x0000000000000003
- active CR3：CR3=0x000000000fe07000
- 新 root 是否 active：新 root 没有激活：active CR3=0xfe07000，而 root PA 是 0x1000。，激活前至少要保留 kernel code、stack、HHDM、IDT/#PF handler 及当前使用的数据。

### 回归

```text
$ make check-page-fault
Limine/UEFI host tools check passed
page-fault check passed: vector 14 reached C with CR2 and error-code evidence
page-fault state: CR2=0x0000400000000000, error=0x0000000000000002, RIP=0xffffffff80001845
page-fault decode: P=0x0000000000000000, W=0x0000000000000001, U=0x0000000000000000, RSVD=0x0000000000000000, I=0x0000000000000000
$ make check-hhdm-page

Limine/UEFI host tools check passed
hhdm-page check passed: allocated PA became an HHDM VA and all 4096 bytes were cleared
hhdm-page state: offset=0xffff800000000000, PA=0x0000000000000000, VA=0xffff800000000000
hhdm-page contents: first/last 0xa5a55a5adeadbeef -> 0x0000000000000000
$ make check-physical-pages

Limine/UEFI host tools check passed
physical-page check passed: two distinct aligned pages moved from free to kernel-owned
physical-page state: first=0x0000000000000000, second=0x0000000000001000, free=0x000000000000cc99->0x000000000000cc97, allocated=0x0000000000000002
$ make check-limine-handoff
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc99 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc97 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:PML4-INDEX=0x0000000000000024 | VMM:PDPT-INDEX=0x00000000000000d1 | VMM:PD-INDEX=0x00000000000000b3 | VMM:PT-INDEX=0x0000000000000189 | VMM:PML4E=0x0000000000002003 | VMM:PDPTE=0x0000000000003003 | VMM:PDE=0x0000000000004003 | VMM:PTE=0x0000000000000003 | VMM:ACTIVE-CR3=0x000000000fe07000 | VMM:ROOT:INACTIVE | VMM:BUILD:OK | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff80001845 | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK'
```

## 预测修订

> 只记录不一致之处；若全部一致，引用绿灯证据写一行即可。

- 原预测：
  - PDPT HHDM VA 是 `0xffff800000000000`；
  - `VMM:BUILD:OK` 在红灯中出现；
  - “PA 0 是第一个可分配 frame”足以解释 `PTE=0x3`；
  - 红灯不破坏第 28 课是“因为这是后续的缺页操作”。
- 真实结果：
  - PDPT HHDM VA 是 `offset + PA = 0xffff800000002000`；
  - 红灯只有 `VMM:LINK:FAIL`，`VMM:BUILD:OK` 不出现；
  - `PTE=0x3` 的 address field 为 PA 0，但 `Present=1, Writable=1`，因此不是空 entry；
  - link 失败后脚手架仍继续执行固定 `PF:TRIGGER`，所以 `PF:DIAG:OK` 继续出现。
- 错误原因或一致证据：第一次计算 HHDM VA 时漏加 PDPT PA；混淆了红灯和绿灯 marker；只解释了 PA 0 的来源，没有检查 PTE flags；也没有沿实际控制流解释旧课证据为何保留。

## 唯一新增的收束

- `VMM:BUILD:OK` 为什么不等于 CPU 已能使用 target VA：它只证明四层 entries 已写进内存；active CR3 仍指向 Limine page tables，CPU 尚未遍历新 root。
- 加载新 `CR3` 前必须保留的当前存活映射：至少包括当前 kernel code/RIP、stack/RSP、HHDM、IDT 与 `#PF` handler，以及切换后仍会读取或输出的 kernel data。否则加载 CR3 后连下一条指令或异常入口都可能不可访问，最终升级成 double/triple fault。

## 仍然不清楚的问题

-
