# 第 30 课学习记录

日期：2026.08.14

> 第一次运行 `make check-kernel-address-space` 前完成“实验前预测”。不预测页面没有给出的 old CR3、精确 RSP 或 PML4E 物理值；错误答案原样保留，实验后写入“预测修订”。

## 实验前预测

### 1. 三个 PML4 indices

- custom target `0x0000123456789000`：0x24
- HHDM base `0xffff800000000000`：0x100
- kernel VA `0xffffffff80001000`：0x1ff
- 计算过程：

```
>>> hex((0x0000123456789000 >> 39) & 0x1ff)
'0x24'
>>> hex((0xffff800000000000 >> 39) & 0x1ff)
'0x100'
>>> hex((0xffffffff80001000 >> 39) & 0x1ff)
'0x1ff'
```

### 2. preserved slot

- clone 后 `destination[custom_index]`：0x2003
- kernel/HHDM/stack 为什么仍可沿 old subtrees 翻译：因为是从老的 PML4 里面复制过来的

### 3. 当前红灯控制流

- 一定出现的 `VMM:*` markers： VMM:BUILD:OK
- 一定不出现的 activation marker：VMM:CLONE:OK VMM:ACTIVATE:OK
- `PF:DIAG:OK` 为什么仍出现：因为用老的也可以运行到这里

## 红灯

### `make check-kernel-address-space`

```text
Limine/UEFI host tools check passed
kernel-address-space check: the active root mappings were not copied into the new root
kernel-address-space check: complete vmm_clone_root_preserving_entry() in kernel/vmm.c
kernel-address-space output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc97 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc95 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:PML4-INDEX=0x0000000000000024 | VMM:PDPT-INDEX=0x00000000000000d1 | VMM:PD-INDEX=0x00000000000000b3 | VMM:PT-INDEX=0x0000000000000189 | VMM:PML4E=0x0000000000002003 | VMM:PDPTE=0x0000000000003003 | VMM:PDE=0x0000000000004003 | VMM:PTE=0x0000000000000003 | VMM:ACTIVE-CR3=0x000000000fe07000 | VMM:ROOT:INACTIVE | VMM:BUILD:OK | VMM:CLONE:FAIL | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff8000184a | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK
make: *** [check-kernel-address-space] Error 1
```

- 失败是否只位于 root clone：是的
- 第 29 课与第 28 课前置证据：因为 PF:DIAG:OK 已经好了

## 我的实现

### validation

- `NULL`：destination == NULL || source == NULL
- in-place clone：destination == source
- preserved index 边界：preserved_index >= VMM_ENTRY_COUNT

### copy loop

```c
for (size_t i = 0; i < VMM_ENTRY_COUNT; i++) {
    if (preserved_index != i) {
        destination[i] = source[i];
    }
}
```

- 为什么 `preserved_index` 不被写入：new PML4[0x24] 已经保存 0x2003；跳过它是为了避免被 old PML4[0x24] 覆盖，从而保留 custom path。

## 绿灯原始观察

### `make check-kernel-address-space`

```text
Limine/UEFI host tools check passed
kernel-address-space check passed: CR3 selects the kernel-owned root and live mappings survive
kernel-address-space roots: old CR3=0x000000000fe07000, new CR3=0x0000000000001000, root PA=0x0000000000001000
kernel-address-space indices: custom=0x0000000000000024, kernel=0x00000000000001ff, HHDM=0x0000000000000100, stack=0x0000000000000100
kernel-address-space alias: 0x0000123456789000 and HHDM both observed 0x30c0ffee30c0ffee
```

- old CR3： 0x000000000fe07000
- new CR3 / root PA：0x0000000000001000 / 0x0000000000001000
- custom/kernel/HHDM/stack PML4 indices：0x0000000000000024 / 0x00000000000001ff / 0x0000000000000100 / 0x0000000000000100

### 回归

```text
$ make check-kernel-page-table
Limine/UEFI host tools check passed
kernel-page-table check passed: four kernel-owned frames form one inactive 4 KiB mapping
kernel-page-table path: VA=0x0000123456789000 -> PA=0x0000000000000000, indices=0x0000000000000024/0x00000000000000d1/0x00000000000000b3/0x0000000000000189
kernel-page-table entries: 0x0000000000002003 -> 0x0000000000003003 -> 0x0000000000004003 -> 0x0000000000000003; active CR3=0x000000000fe07000

$ make check-page-fault

Limine/UEFI host tools check passed
page-fault check passed: vector 14 reached C with CR2 and error-code evidence
page-fault state: CR2=0x0000400000000000, error=0x0000000000000002, RIP=0xffffffff8000184a
page-fault decode: P=0x0000000000000000, W=0x0000000000000001, U=0x0000000000000000, RSVD=0x0000000000000000, I=0x0000000000000000

$ make check-hhdm-page
Limine/UEFI host tools check passed
hhdm-page check passed: allocated PA became an HHDM VA and all 4096 bytes were cleared
hhdm-page state: offset=0xffff800000000000, PA=0x0000000000000000, VA=0xffff800000000000
hhdm-page contents: first/last 0xa5a55a5adeadbeef -> 0x0000000000000000

$ make check-physical-pages

Limine/UEFI host tools check passed
physical-page check passed: two distinct aligned pages moved from free to kernel-owned
physical-page state: first=0x0000000000000000, second=0x0000000000001000, free=0x000000000000cc97->0x000000000000cc95, allocated=0x0000000000000002

$ make check-limine-handoff
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc97 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc95 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:PML4-INDEX=0x0000000000000024 | VMM:PDPT-INDEX=0x00000000000000d1 | VMM:PD-INDEX=0x00000000000000b3 | VMM:PT-INDEX=0x0000000000000189 | VMM:PML4E=0x0000000000002003 | VMM:PDPTE=0x0000000000003003 | VMM:PDE=0x0000000000004003 | VMM:PTE=0x0000000000000003 | VMM:ACTIVE-CR3=0x000000000fe07000 | VMM:ROOT:INACTIVE | VMM:BUILD:OK | VMM:CLONE:OK | VMM:OLD-CR3=0x000000000fe07000 | VMM:PRESERVED-INDEX=0x0000000000000024 | VMM:KERNEL-PML4-INDEX=0x00000000000001ff | VMM:HHDM-PML4-INDEX=0x0000000000000100 | VMM:STACK-VA=0xffff80000dd3ff20 | VMM:STACK-PML4-INDEX=0x0000000000000100 | VMM:KERNEL-OLD-PML4E=0x000000000fe02027 | VMM:KERNEL-COPIED-PML4E=0x000000000fe02027 | VMM:HHDM-OLD-PML4E=0x000000000dd2d027 | VMM:HHDM-COPIED-PML4E=0x000000000dd2d027 | VMM:STACK-OLD-PML4E=0x000000000dd2d027 | VMM:STACK-COPIED-PML4E=0x000000000dd2d027 | VMM:NEW-CR3=0x0000000000001000 | VMM:TARGET-BEFORE=0x0000000000000000 | VMM:TARGET-AFTER=0x30c0ffee30c0ffee | VMM:HHDM-AFTER=0x30c0ffee30c0ffee | VMM:ALIAS:OK | VMM:ACTIVATE:OK | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff8000184a | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK'
```

## 预测修订

> 导师复核：三个 PML4 indices 与 preserved slot 均和机器结果一致。红灯预测漏写了实际出现的 `VMM:CLONE:FAIL`；完整边界是 `VMM:BUILD:OK → VMM:CLONE:FAIL → CR3 不变 → PF:DIAG:OK`。原预测保留在上方，不再逐项重复抄写。

## 我的解释

### 1. shallow copy 与 ownership

- 复制 PML4E 只复制了其中保存的 PDPT 物理地址，没有复制下级页表。因此新旧 PML4 仍指向相同的 Limine-owned PDPT/PD/PT。kernel 在建立自己的下级页表并移除这些引用之前，不能回收或重新分配相应的 bootloader page-table frames。

## 仍然不清楚的问题

-
