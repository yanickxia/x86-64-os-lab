# 第 31 课学习记录

日期：2026.08.16

## 实验前预测

handler 补上 PTE 并原样返回后，触发 fault 的 store 会被跳过还是重新执行？为什么？

我的预测：应该会被跳过，因为 RIP 没有重置，直接走到下面去了

## 红灯

第一次运行 `make check-demand-page` 的结果：

Limine/UEFI host tools check passed
demand-page check: demand-write policy rejected the eligible synthetic fault
demand-page check: complete vmm_resolve_demand_write() in kernel/vmm.c
demand-page output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc94 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc92 | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | VMM:FRAMES:OK | VMM:ROOT-PA=0x0000000000001000 | VMM:PDPT-PA=0x0000000000002000 | VMM:PD-PA=0x0000000000003000 | VMM:PT-PA=0x0000000000004000 | VMM:TARGET-VA=0x0000123456789000 | VMM:TARGET-PA=0x0000000000000000 | VMM:PML4-INDEX=0x0000000000000024 | VMM:PDPT-INDEX=0x00000000000000d1 | VMM:PD-INDEX=0x00000000000000b3 | VMM:PT-INDEX=0x0000000000000189 | VMM:PML4E=0x0000000000002003 | VMM:PDPTE=0x0000000000003003 | VMM:PDE=0x0000000000004003 | VMM:PTE=0x0000000000000003 | VMM:ACTIVE-CR3=0x000000000fe07000 | VMM:ROOT:INACTIVE | VMM:BUILD:OK | VMM:CLONE:OK | VMM:OLD-CR3=0x000000000fe07000 | VMM:PRESERVED-INDEX=0x0000000000000024 | VMM:KERNEL-PML4-INDEX=0x00000000000001ff | VMM:HHDM-PML4-INDEX=0x0000000000000100 | VMM:STACK-VA=0xffff80000dd3fed0 | VMM:STACK-PML4-INDEX=0x0000000000000100 | VMM:KERNEL-OLD-PML4E=0x000000000fe02027 | VMM:KERNEL-COPIED-PML4E=0x000000000fe02027 | VMM:HHDM-OLD-PML4E=0x000000000dd2d027 | VMM:HHDM-COPIED-PML4E=0x000000000dd2d027 | VMM:STACK-OLD-PML4E=0x000000000dd2d027 | VMM:STACK-COPIED-PML4E=0x000000000dd2d027 | VMM:NEW-CR3=0x0000000000001000 | VMM:TARGET-BEFORE=0x0000000000000000 | VMM:TARGET-AFTER=0x30c0ffee30c0ffee | VMM:HHDM-AFTER=0x30c0ffee30c0ffee | VMM:ALIAS:OK | VMM:ACTIVATE:OK | DEMAND:POLICY:FAIL | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff80001898 | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK
make: *** [check-demand-page] Error 1

## 我的实现

只概括 `vmm_resolve_demand_write()` 的成功条件与最终状态变化，不必抄完整函数：
if (report == NULL || pte == NULL || (expected_virtual_page & (VMM_PAGE_SIZE - 1)) != 0 ||
        (physical_address & ~VMM_PAGE_ADDRESS_MASK) != 0) {
        return false;
    }

    if (*pte != 0) {
        return false;
    }

    uint64_t fault_page = report->address & ~(VMM_PAGE_SIZE - 1);

    if (fault_page != expected_virtual_page) {
        return false;
    }

    if (report->error_code != PAGE_FAULT_WRITE) {
        return false;
    }

    *pte = physical_address | VMM_PAGE_PRESENT | VMM_PAGE_WRITABLE;

    return true;
}

-

## 绿灯原始观察

粘贴 `make check-demand-page` 最后三行摘要即可：

```text
$ make check-demand-page
Limine/UEFI host tools check passed
demand-page pure-C checks passed
demand-page check passed: #PF installed one PTE and IRETQ retried the store
demand-page mapping: VA=0x000012345678a000, PA=0x0000000000005000, PTE 0x0000000000000000 → 0x0000000000005003
demand-page alias: resumed VA and HHDM both observed 0x31d00d0031d00d00
```

## 预测修订

原预测与真实结果是否一致？若不一致，用一行说明错在哪里：

> 导师修订：原预测不一致。`#PF` 保存的是 faulting store 的 `RIP`；handler 不修改它，`IRETQ` 就恢复到同一条 store，使其在新 mapping 下重试，而不是自动走到下一条指令。

## 我的解释

为什么第 19 课需要推进 `UD2` 的 saved `RIP`，本课却必须保留 faulting store 的 saved `RIP`？PTE 与 `INVLPG` 分别修复了什么？

我的回答：19 课的时候还不能真的去运行缺页操作，但是现在是可以的

INVLPG 针对包含该线性地址的 page 失效 TLB entry。与重载 CR3 相比，它表达的范围更小：本课只改变一个 leaf mapping，就只失效一个 VA。该特权指令已由脚手架封装在 invalidate_page()

> 导师修订：关键差别不是“能不能运行缺页操作”。第 19 课的 `UD2` 本身永远非法，环境无法把它修好，只能推进 saved `RIP` 跳过；本课的 store 本身合法，失败原因只是 PTE 缺失。写 PTE 修复 page-table mapping，`INVLPG` 丢弃该 VA 可能残留的翻译缓存状态，随后保留 saved `RIP` 才能让原 store 正确重试。

## 课中追问汇总

### 1. `pte` 和 `*pte` 有什么区别？

- `pte` 是指向页表项的指针，也就是“PTE 放在哪里”。前面排除 `pte == NULL` 后，`pte != 0` 必然成立。
- `*pte` 是该地址中保存的 64-bit 页表项内容，也就是“PTE 现在是什么”。本课必须检查 `*pte == 0`，避免覆盖已经存在的 mapping 或软件状态。

### 2. 不修改 saved `RIP`，为什么不是跳到下一条指令？

- CPU 产生 fault 时保存的是 faulting store 的 `RIP`。`IRETQ` 恢复这个值，不会替软件自动加上指令长度。
- 因此 handler 修好 PTE 后保留 saved `RIP`，CPU 会重试同一条 store；只有 handler 主动修改 saved `RIP`，才会跳到别处。
- 这也解释了本课第一次修正为什么必要：`UD2` 的原因不能消失，而缺页的原因可以通过 mapping 消失。

## 仍然不清楚的问题

-
