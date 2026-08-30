# 第 31 课：让 `#PF` 修复一次按需映射

## 先修知识

开始前只需要记住第 28–30 课留下的三个事实：

- 第 28 课已经能从 `CR2`、page-fault error code 和 saved `RIP` 判断一次缺页访问是什么。
- 第 29 课已经有一条 kernel-owned `PML4 → PDPT → PD → PT` 路径，并能写入 leaf PTE。
- 第 30 课已把这张 PML4 装入 `CR3`；CPU 现在真的使用它做地址翻译。

此前的 `#PF` handler 只能报告然后停机。本课第一次让异常处理改变系统状态并恢复原程序。

## 本课只引入一个机制

对一个事先指定的 kernel virtual page，第一次写入时 PTE 仍为空，因此 CPU 产生 `#PF`。handler 确认这是允许恢复的访问后，把一个预留 frame 写入 PTE，失效该 VA 的旧 TLB 状态，然后返回。CPU 再次执行原来的 store，这次翻译成功。

```text
store demand VA
       │
       ▼
PTE.P = 0 ──► #PF ──► validate policy ──► PTE = PA | P | RW
                                                    │
                                                    ▼
                                               INVLPG VA
                                                    │
                                                    ▼
                         same saved RIP ◄── IRETQ ──┘
                                │
                                ▼
                     retry the same store → success
```

这已经是 demand paging 的最小闭环：**某个访问先暴露需求，kernel 再建立映射，原访问随后重试。**

## 1. 从“诊断 fault”到“处理 fault”

第 28 课把所有 `#PF` 都当成致命错误：打印证据后 halt。这适合建立安全网，但真正的 OS 不能把每次 non-present page 都视为 bug。例如用户进程第一次碰到尚未分配的 heap page、文件映射第一次被访问、copy-on-write page 第一次被写，都可能由 page fault 驱动后续工作。

一次 fault 能否恢复，不由 `#PF` 这个名字决定，而由 kernel policy 决定：

```text
CPU 提供事实：CR2、error code、saved RIP
kernel 解释事实：这是谁的地址？哪种访问？是否允许？
kernel 执行动作：补 mapping、拒绝进程，或判定 kernel bug
```

本课的 policy 刻意很窄，只接受：

- fault address 落在唯一指定的 4 KiB virtual page；
- `P=0, W=1, U=0, RSVD=0, I/D=0`，即 supervisor 对 non-present page 的普通数据写；
- 要写入的 PTE 仍为 0；
- 预留 PA 和目标 VA 都满足 4 KiB 对齐合同。

其他 fault 继续走第 28 课的诊断并停机。真实内核还会按 address-space、VMA、权限、进程身份和 backing object 做更完整的决策。

## 2. producer、consumer 与 observer

这次有三个角色，不要把它们揉成一个函数：

| 角色 | 本课是谁 | 负责什么 |
| --- | --- | --- |
| producer | CPU 与 `page_fault_decode()` | 产生并解码 `CR2/error/RIP` 事实 |
| consumer | `vmm_resolve_demand_write()` | 根据 policy 决定能否发布 leaf PTE |
| observer | debug console、检查器与 HHDM alias | 证明 PTE 变化、控制流恢复和同一 frame 内容 |

`vmm_resolve_demand_write()` 不读取 `CR2`、不执行 `IRETQ`、不分配 frame，也不输出日志。它只消费已经解码好的 report，并在全部条件成立时完成一次 ownership publication：

```text
empty PTE
   ↓
physical_address | PRESENT | WRITABLE
```

这样 policy 可以用普通 host C 测试，异常入口和硬件恢复则由 QEMU 运行证据验证。

## 3. 为什么本课先预留 frame

完整 demand allocator 往往会在 fault path 中申请物理页。但我们当前的 monotonic PMM 还没有锁、reentrancy contract 或 per-CPU 状态；此时把 `pmm_alloc_page()` 直接塞进异常 handler，会同时引入“异常上下文能否安全分配”这一新问题。

因此脚手架在触发 fault **之前**完成：

1. 从 PMM 取得一个 frame；
2. 通过 HHDM 清零；
3. 把 PA 和目标 PTE 保存进一次性的 `demand_page` context；
4. 保持 leaf PTE 为 0。

发生 fault 后只延迟“发布 mapping”，不延迟“取得 frame”。准确地说，这是 **lazy mapping with a pre-reserved frame**，不是完整的 lazy physical allocation。这个收缩让本课只研究 fault recovery。

## 4. 为什么 `IRETQ` 不推进 `RIP`

第 19 课的 `UD2` 是故意放进去的非法指令。handler 若原样返回，CPU 会再次执行同一个 `UD2`，于是永远重复 `#UD`。当时我们把 saved `RIP` 加 2，是为了明确跳过那条无法变得合法的指令。

本课不同。faulting instruction 本身是一条合法 store；失败原因只是当时的地址翻译缺失。handler 已经改变 PTE，原指令现在有机会成功，因此必须保留 saved `RIP`：

```text
第 19 课：UD2 仍然非法      → 修改 RIP，跳过它
第 31 课：store 本身合法    → 修复环境，保留 RIP，重试它
```

如果 page-fault handler 也把 `RIP` 加到下一条指令，store 会被静默跳过。程序表面上“继续运行”，但目标内存从未写入 marker；这比立即崩溃更危险。

`page_fault_entry` 的汇编恢复路径由脚手架提供：C handler 返回后恢复所有 GPR，丢弃 CPU 压入的 error code，再执行 `IRETQ`。本课不要求手写异常汇编。

## 5. `INVLPG` 在这里做什么

CPU 不会在每次访问时都从 PML4 一路读到 PTE；它会缓存地址翻译和部分 page-walk 状态。kernel 修改当前 active page table 后，软件必须按架构规则让相关缓存状态失效。

```asm
invlpg [address]
```

`INVLPG` 针对包含该线性地址的 page 失效 TLB entry。与重载 `CR3` 相比，它表达的范围更小：本课只改变一个 leaf mapping，就只失效一个 VA。该特权指令已由脚手架封装在 `invalidate_page()`，你只需要理解它位于“写 PTE”和“返回重试”之间。

更完整的多核内核还要通知其他 CPU 丢弃同一地址空间的缓存，这叫 TLB shootdown；本课仍是单 CPU，不展开多核协议。

## 6. 本课的具体地址路径

第 29、30 课使用：

```text
mapped VA = 0x0000123456789000
PT index  = 0x189
```

本课选择相邻一页：

```text
demand VA = 0x000012345678a000
PT index  = 0x18a
```

两者的 PML4、PDPT 和 PD indices 相同，因此复用已经 active 的三层 parent entries 和同一张 PT。区别只在相邻的 leaf slot：

```text
PT[0x189] = lesson-30 PA | P | RW
PT[0x18a] = 0                         before fault
PT[0x18a] = demand PA    | P | RW     after handler
```

这就是为什么本课不再分配四张 page-table pages：层级已经存在，我们只补一个 leaf mapping。

## 7. 红灯为什么安全

当前 `kernel/vmm.c` 中的 `vmm_resolve_demand_write()` 固定返回 `false`。脚手架不会立刻让真实 CPU 跳进一个注定无法恢复的 fault；它先构造一份与真实事件相同的 synthetic report，并用临时 PTE 调用该函数。

```text
red helper
   ↓
DEMAND:POLICY:FAIL
   ↓
不触发 demand store
   ↓
继续运行旧 PF:TRIGGER → PF:DIAG:OK
```

synthetic report 不是伪造绿灯，而是 red-phase guard：它只决定是否开放真实触发器。绿灯检查仍要求 QEMU 真的产生 `#PF`、handler 真的修改 active PTE、`IRETQ` 真的恢复 store。

## 实验前预测

先在 `notes/06-Limine与内核主线/note-31.md` 只回答这一题：

> handler 补上 PTE 后原样返回，没有修改 saved `RIP`。触发 fault 的 store 会被跳过，还是会被重新执行？为什么？

不需要预测 PA、RIP 或完整日志的精确数值。

## 运行红灯

```sh
make check-demand-page
```

预期看到：

```text
demand-page check: demand-write policy rejected the eligible synthetic fault
demand-page check: complete vmm_resolve_demand_write() in kernel/vmm.c
```

运行下面的命令可以同时查看 TODO、异常返回桥和最终 ELF 中的 `INVLPG/IRETQ`：

```sh
make inspect-demand-page
```

## 练习

只修改 `kernel/vmm.c` 中的 `vmm_resolve_demand_write()`。成功路径需要按顺序建立四道防线：

1. 所有 pointer 有效，VA/PA 满足对齐与 address-mask 合同；
2. report 的 faulting address 按 4 KiB 向下对齐后等于 `expected_virtual_page`；
3. report 确实描述 error code `0x2` 对应的 non-present supervisor data write；
4. `*pte` 仍为 0，最后才写入 `physical_address | PRESENT | WRITABLE`。

失败路径必须返回 `false`，而且不能修改 `*pte`。成功路径返回 `true`。PA 0 仍然是合法 frame，不能用 `physical_address == 0` 当失败条件。

如果需要提示，按层次展开：

<details>
<summary>提示 1：怎样得到 fault address 所在页</summary>

`address & ~(VMM_PAGE_SIZE - 1)` 会清除 12-bit page offset。

</details>

<details>
<summary>提示 2：怎样判断 PA 只包含合法 page address bits</summary>

参考 `vmm_map_single_4k()` 已使用的 `physical_address & ~VMM_PAGE_ADDRESS_MASK`。

</details>

<details>
<summary>提示 3：成功写入的三个字段</summary>

frame address、`VMM_PAGE_PRESENT`、`VMM_PAGE_WRITABLE` 用 bitwise OR 合并。

</details>

## 绿灯取证

完成后运行：

```sh
make check-demand-page
```

检查器会验证这一条顺序链：

```text
DEMAND:TRIGGER
→ DEMAND:PF:CR2
→ PTE 0x0 → PA | 0x3
→ DEMAND:MAP:OK
→ DEMAND:RESUME:OK
→ 旧 PF:DIAG:OK
```

最后三行摘要已足够作为绿灯记录，不要求把 debug console 的每个字段重新抄进笔记。测试还会在宿主上覆盖 invalid pointer、错页、未对齐、错误访问类型、非空 PTE 与 PA 0 等边界。

## 唯一新增的解释题

在 `notes/06-Limine与内核主线/note-31.md` 用一小段话说明：

> 为什么第 19 课需要推进 `UD2` 的 saved `RIP`，本课却必须保留 faulting store 的 saved `RIP`？PTE 与 `INVLPG` 分别修复了什么？

不要再重复解释四级页表 indices、HHDM 公式或 error-code 各 bit；这些已经有历史证据。

## 本课边界

完成本课后已经有一次可恢复 page fault，但还没有：

- 通用 virtual-memory area（VMA）数据结构；
- 在 fault handler 内安全调用的 allocator；
- user/kernel 权限与 NX/W^X policy；
- unmap、free、copy-on-write、swap 或 file-backed pages；
- SMP TLB shootdown。

它不是完整 VM subsystem，却建立了后续 lazy allocation、用户地址空间与 copy-on-write 共用的核心控制流。

## 完成标准

- 保留原始预测，并在绿灯后用一行修订结论。
- `make check-demand-page` 通过。
- 第 28–30 课的 `check-page-fault`、`check-kernel-page-table`、`check-kernel-address-space` 仍通过。
- 能解释为什么恢复型 fault 修复原因后重试原指令，而不是无条件推进 `RIP`。
