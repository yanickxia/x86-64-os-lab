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

<!-- source: sidechat:01a00eba-5d0e-74a3-af0e-f46cd22b1c98 -->

### 1. 为什么 faulting address 向下对齐后要等于 `expected_virtual_page`？

- `report->address` 来自 `CR2`，表示真正发生访问的字节地址；它可能落在一页中的任意 offset，并不一定恰好是页首。
- `expected_virtual_page` 表示内核事先允许按需建立映射的那一整页，所以它必须是 4 KiB 对齐的页首地址。
- `report->address & ~(VMM_PAGE_SIZE - 1)` 会清掉低 12-bit page offset。对齐后的结果相等，表示 fault 确实发生在获准处理的那一页，而不是别的地址。
- 本实验恰好向页首 `0x000012345678a000` 写入，但用“页身份”比较，才能覆盖该页内的所有合法 offset。

### 2. 触发写入的地址是故意选择的吗？它对应哪个 index？

- 是。`LESSON_DEMAND_ADDRESS` 被定义为上一课目标地址再加一页：`0x0000123456789000 + 0x1000 = 0x000012345678a000`。
- 两个地址共享相同的 PML4、PDPT 和 PD 路径，只有 PT index 从 `0x189` 变为相邻的 `0x18a`。这样可以复用已经建立的上三级页表，只把新的 leaf PTE 留为 0。
- 内核先为它预留 physical frame，并把 VA、PA 和 `&pt[0x18a]` 放入 `demand_page`；随后对该 VA 的 store 才会稳定地产生本课预期的 non-present write fault。

### 3. `vmm_resolve_demand_write()` 的实现检查结果

- 当前实现的方向正确，并已通过 `make check-demand-page`：先拒绝空指针、未对齐的 expected VA 和非法 PA，再确认目标 PTE 为空、fault 属于预期页且 error code 恰为 `PAGE_FAULT_WRITE`。
- 所有失败分支都发生在写 PTE 之前，因此不会破坏原 entry；成功分支最后才发布 `physical_address | PRESENT | WRITABLE`。
- 这里的函数只负责判断策略并写入一个 PTE。`demand_page.armed = false`、`INVLPG` 和异常返回后的指令重试由外层 page-fault handler 负责。

## 仍然不清楚的问题

-
