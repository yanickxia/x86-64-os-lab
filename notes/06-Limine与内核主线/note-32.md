# 第 32 课学习记录

日期：2026.08.19

## 实验前预测

demand store 尚未执行时，`0x000012345678a000` 的三个 parent entries 都 present，但 `PT[0x18a] == 0`。`vmm_walk_to_pte()` 应返回 `false`，还是返回 `true` 并交出一个 pointer？caller 随后通过这个 pointer 读到的 entry 值是什么？

我的预测：PT[0x18a] == 0 说明拿到了初始化的table entry 所以应该 vmm_walk_to_pte 返回 true，parent path 已有，只缺 leaf”，然后分配一个地址然后返回那个具体的地址？

## 红灯

第一次运行 `make check-page-table-walk` 的结果：

```text
Limine/UEFI host tools check passed
page-table walk check: reusable walker is incomplete
page-table walk check: complete vmm_walk_to_pte() in kernel/vmm.c
page-table walk output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc93 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc91 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:PML4-INDEX=0x0000000000000024 | VMM:PDPT-INDEX=0x00000000000000d1 | VMM:PD-INDEX=0x00000000000000b3 | VMM:PT-INDEX=0x0000000000000189 | VMM:PML4E=0x0000000000002003 | VMM:PDPTE=0x0000000000003003 | VMM:PDE=0x0000000000004003 | VMM:PTE=0x0000000000000003 | VMM:ACTIVE-CR3=0x000000000fe07000 | VMM:ROOT:INACTIVE | VMM:BUILD:OK | VMM:CLONE:OK | VMM:OLD-CR3=0x000000000fe07000 | VMM:PRESERVED-INDEX=0x0000000000000024 | VMM:KERNEL-PML4-INDEX=0x00000000000001ff | VMM:HHDM-PML4-INDEX=0x0000000000000100 | VMM:STACK-VA=0xffff80000dd3fec0 | VMM:STACK-PML4-INDEX=0x0000000000000100 | VMM:KERNEL-OLD-PML4E=0x000000000fe02027 | VMM:KERNEL-COPIED-PML4E=0x000000000fe02027 | VMM:HHDM-OLD-PML4E=0x000000000dd2d027 | VMM:HHDM-COPIED-PML4E=0x000000000dd2d027 | VMM:STACK-OLD-PML4E=0x000000000dd2d027 | VMM:STACK-COPIED-PML4E=0x000000000dd2d027 | VMM:NEW-CR3=0x0000000000001000 | VMM:TARGET-BEFORE=0x0000000000000000 | VMM:TARGET-AFTER=0x30c0ffee30c0ffee | VMM:HHDM-AFTER=0x30c0ffee30c0ffee | VMM:ALIAS:OK | VMM:ACTIVATE:OK | VMM:WALK:ROOT-PA=0x0000000000001000 | VMM:WALK:MAPPED-VA=0x0000123456789000 | VMM:WALK:MAPPED-PTE=0xffffffffffffffff | VMM:WALK:EMPTY-VA=0x000012345678a000 | VMM:WALK:EMPTY-PTE=0xffffffffffffffff | VMM:WALK:RED | DEMAND:POLICY:OK | DEMAND:VA=0x000012345678a000 | DEMAND:PA=0x0000000000005000 | DEMAND:PT-INDEX=0x000000000000018a | DEMAND:TRIGGER | DEMAND:PF:CR2=0x000012345678a000 | DEMAND:PF:ERROR=0x0000000000000002 | DEMAND:PF:RIP=0xffffffff800022c3 | DEMAND:PTE-BEFORE=0x0000000000000000 | DEMAND:PTE-AFTER=0x0000000000005003 | DEMAND:MAP:OK | DEMAND:VALUE-VA=0x31d00d0031d00d00 | DEMAND:VALUE-HHDM=0x31d00d0031d00d00 | DEMAND:RESUME:OK | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff8000189a | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK
make: *** [check-page-table-walk] Error 1
```

## 我的实现

只概括每一级如何完成 `entry → next table PA → HHDM pointer`，以及成功时最终发布什么；不必抄完整函数：

- 先检查 output pointer、root PA 的格式，以及 `hhdm_offset + root PA` 不会溢出，再把 root PA 转成 PML4 的 HHDM pointer。
- 在 PML4、PDPT、PD 逐级读取目标 index：每个 parent 都必须 `PRESENT=1` 且 `PS=0`；随后用 address mask 取出下一张表的 PA，检查 HHDM 加法不会溢出，再转成下一张表的 pointer。
- 到达 PT 后不检查 leaf 是否 present，而是最后一次性把 `&table[VMM_PT_INDEX(virtual_address)]` 写入 output；任一失败路径都不会修改 caller 的 pointer。

## 绿灯原始观察

粘贴 `make check-page-table-walk` 最后四行摘要即可：

```text
page-table walk pure-C checks passed
page-table walk check passed: active root reached both adjacent leaf slots
page-table walk mapped leaf: VA=0x0000123456789000, PTE=0x0000000000000063
page-table walk empty leaf: VA=0x000012345678a000, PTE=0x0000000000000000
```

## 预测修订

原预测与真实结果是否一致？若不一致，错在混淆了 parent path 与 leaf mapping 的哪一层？

- 原预测：parent path 已有，因此 walker 会返回 `true`；同时猜测它会再分配一个地址并返回该地址。
- 真实结果：walker 返回 `true`，交出 `&PT[0x18a]`；caller 通过这个 pointer 读到的 entry 值为 `0`。
- 修订原因：原预测中“parent path 已有，所以返回 `true`”是对的；“然后分配一个地址”是错误部分。walker 不分配 frame 或 page-table page，只返回已经存在的 empty leaf slot。

## 我的解释

为什么 API 返回 `uint64_t **pte`，而不是只返回当前 entry 的 `uint64_t` 数值？这对后续 mapper 或 page-fault handler 有什么实际用途？

我的回答：没有返回这个啊，我们只是把 pte 写入了，就是把最后一页写进去，然后触发缺页

导师修订：这里确实通过 output parameter 返回了一个 pointer，但没有写入“最后一页”，也不会触发 `#PF`。caller 可以这样接收它：

```c
uint64_t *leaf = NULL;
vmm_walk_to_pte(root_pa, hhdm_offset, va, &leaf);
```

函数中的 `pte` 指向 caller 的 `leaf` 变量；执行 `*pte = &table[index]` 后，caller 的 `leaf` 就指向真实 PTE。只返回 `uint64_t` 会得到 entry 的数值快照；返回 pointer 后，后续 mapper 才能通过 `*leaf = physical_address | flags` 修改真实页表项。只有 CPU 随后访问一个尚未映射的 VA 时才可能触发 `#PF`，walker 本身只是读取页表并返回 slot 地址。

## 课中追问汇总

- 问题原意：`uint64_t **pte` 到底“返回”了什么？结论：函数通过 `*pte = ...` 修改 caller 的 `uint64_t *leaf` 变量，使它指向页表内真实的 64-bit leaf slot。
- 问题原意：找到 empty leaf 后 walker 会不会顺便分配或触发缺页？结论：不会；它只定位 slot。分配、发布 mapping、TLB 失效和实际内存访问属于后续调用者或 CPU 的工作。

## 仍然不清楚的问题

-
