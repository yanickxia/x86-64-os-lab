# 第 28 课：让 Page Fault 说清楚哪里错了

第 27 课已经证明，kernel 可以通过 Limine HHDM 访问并初始化自己拥有的 physical frame。下一阶段要开始创建和修改页表；一旦 entry 地址、层级或权限写错，CPU 最常见的反馈就是 page fault（`#PF`）。

如果没有自己的异常入口，结果通常只是重启、停机或黑屏。这会把“哪一个 VA 出错、做了什么访问、为什么失败”全部隐藏起来。

所以本课先建立诊断安全网：故意向一个未映射 VA 写入，让 vector 14 进入 kernel，读取 `CR2` 与 CPU error code，并把原始位解码成可读报告。

```text
故意写未映射 VA
  → CPU page-table walk 失败
  → #PF / vector 14
  → IDT gate → assembly bridge → C handler
  → CR2 + error code + fault RIP
  → page_fault_decode()
  → supervisor write to a non-present page
```

## 先修知识

开始前只需掌握：

1. C 解引用的是 VA，CPU 再通过当前页表翻译成 PA。
2. 当前 `CR3` 仍指向 Limine page tables；kernel-owned page tables 尚未建立。
3. 第 19 课见过 `#UD → IDT → assembly → C`，但那属于历史自制-loader 路径。
4. 第 27 课已经区分 ownership、mapping 和 contents。
5. `uint64_t` 中的 bit mask 可以提取布尔字段。

本课不会要求你手写 IDT descriptor，也不会让你实现异常汇编入口。

## 本课只引入一个机制

唯一由你实现的新机制是 **page-fault evidence decoding**：

```c
bool page_fault_decode(uint64_t address,
                       uint64_t error_code,
                       uint64_t rip,
                       struct page_fault_report *report);
```

它把硬件提供的原始证据转成结构化报告。本课不做：

- 修复缺页并返回原指令；
- demand paging、copy-on-write 或 swap；
- kernel-owned page tables；
- 完整 256-vector handler policy；
- 用户态 page fault；
- 中断控制器或 timer IRQ。

IDT、assembly bridge、读取 `CR2`、打印和停机由脚手架提供。这些是理解诊断链必需、但不值得再次消耗主线课时的 x86 胶水。

## 1. Page fault 不是“程序崩了”的同义词

Page fault 是 CPU 地址翻译或分页权限检查失败时产生的同步异常，x86-64 的 vector 是 14。

“同步”意味着它由当前指令直接触发：本课中的 store 尚未完成，CPU 保存的 RIP 指向那条出错的写指令。它不同于键盘或 timer 等外部设备在任意指令边界送来的中断。

真实 OS 对 `#PF` 的策略取决于上下文：

```text
用户 VA 尚未分配      → 可能按需分配并恢复
copy-on-write 写入     → 复制 frame、改 mapping、恢复
用户访问非法 VA       → 终止当前进程
kernel 页表实现错误    → 打印诊断并 panic
```

本课属于最后一种。我们故意制造 kernel-mode fault，目标是可靠停机并留下证据，而不是恢复。

## 2. 三份证据回答三个不同问题

### 2.1 `CR2`：哪个线性/虚拟地址无法访问

发生 `#PF` 时，CPU 把造成异常的 linear address 写进 control register `CR2`。在当前 flat 64-bit 地址模型里，可以把它理解为出错 VA。

本课触发代码固定为：

```c
#define LESSON_PAGE_FAULT_ADDRESS UINT64_C(0x0000400000000000)

*(volatile uint64_t *)(uintptr_t)LESSON_PAGE_FAULT_ADDRESS = UINT64_C(0x28);
```

因此成功进入 handler 后，`CR2` 应是 `0x0000400000000000`。右侧的 `0x28` 只是准备写入的数据，不是 fault address，也不是 error code。

### 2.2 error code：这是什么类型的访问失败

CPU 在进入 `#PF` handler 前，会把一个 error code 压入异常栈。低位含义为：

| bit | 本课命名 | 0 | 1 |
| ---: | --- | --- | --- |
| 0 | `P` / `present` | non-present translation | protection violation |
| 1 | `W/R` / `write` | read access | write access |
| 2 | `U/S` / `user` | supervisor access | user access |
| 3 | `RSVD` | 无 reserved-bit violation | page-table reserved bit 写成 1 |
| 4 | `I/D` / `instruction_fetch` | data access | instruction fetch |

注意 bit 0 常被误读。`P=0` 不是“页面现在 present=0 的布尔打印”这么简单，它表示异常原因是翻译链中存在 non-present entry；`P=1` 表示 entry 存在，但权限检查失败。

### 2.3 saved RIP：哪条指令发起了访问

`CR2` 告诉你数据地址，saved RIP 告诉你 faulting instruction 的地址。例如：

```text
CR2 = 0x0000400000000000       出错的数据 VA
RIP = 0xffffffff8000....       发起 store 的 kernel instruction
```

二者通常不同。调试时可用 RIP 回到反汇编/源码定位指令，再用 CR2 检查它操作的 VA。

## 3. 为什么本课预期 error code 是 `0x2`

本课 store 的输入是公开且固定的：

- 目标 VA 没有 mapping；
- 操作是 write；
- CPU 当前在 ring 0 / supervisor；
- 这是 data store，不是取指；
- 没有构造 reserved-bit violation。

所以五个 bit 为：

```text
P    = 0
W/R  = 1
U/S  = 0
RSVD = 0
I/D  = 0
```

组装原始数值：

```text
error = 0b00010 = 0x2
```

这句话的完整读法是：

> supervisor mode 对一个 non-present virtual page 发起 data write。

不能只说“写错误”，也不能把 `0x2` 当作 vector number；vector 是 14，`0x2` 是该 vector 的本次 error code。

## 4. 证据是谁产生、谁消费

| 角色 | 本课是谁 | 边界 |
| --- | --- | --- |
| fault producer | CPU/MMU | page walk/权限检查失败后产生 vector 14 |
| routing table | `kernel_idt[256]` | vector 14 指向 `page_fault_entry` |
| architecture bridge | `faults_asm.asm` | 保存 GPR，取出 CPU-pushed error code 和 frame，调用 C |
| raw-evidence reader | `page_fault_handler()` | 尽早读 `CR2`，拿到 saved RIP |
| evidence decoder | `page_fault_decode()` | 纯 C：复制原始值并解码 bits 0..4 |
| policy | 当前 handler | 对预期诊断打印 `PF:DIAG:OK`，然后 halt |
| observer | `check-page-fault` | 检查 CR2、error、RIP 与五个字段 |

`page_fault_decode()` 不读取 `CR2`，因为 control-register access 是架构边界；它也不打印或 halt，因而可以用合成输入独立推演和测试。

## 5. 第 19 课的 #UD 为什么不能直接复用

两课概念相似，但运行路径和异常栈不同：

```text
第 19 课                           第 28 课
自制 BIOS/stage2 路径              Limine/UEFI 高半 kernel 路径
vector 6 / #UD                    vector 14 / #PF
#UD 没有 CPU error code            #PF 有 CPU-pushed error code
修改 saved RIP 后 IRETQ 恢复       诊断后 halt，不恢复 faulting store
7-entry teaching IDT               256-entry kernel IDT scaffold
```

第 19 课的 `exception_frame` 从 saved RIP 开始；本课 assembly 必须先跨过 error code，才能把 `interrupt_frame *` 传给 C。若错一个 8-byte 槽，C 看到的 RIP、CS 等字段就会全部错位。

这些布局由脚手架提供，你只需能解释为什么 `#PF` 多了 error code。

## 6. 为什么先读 `CR2`

`CR2` 不是 CPU 自动压入当前异常栈的字段。handler 必须执行 `mov ..., cr2` 主动读取。

内核应尽早保存它，因为 handler 自己若在读取前再次触发 page fault，新的 fault address 会覆盖 `CR2`，原始现场就丢了。本课 C handler 进入后立即读取，再调用 decoder。

## 7. IDT 安全网建立了什么，又没建立什么

脚手架提供一个 256-entry IDT array，但当前只填写 vector 14：

```text
IDT[14] → page_fault_entry
```

这足以诊断本课 page fault，却不代表完整异常系统已经完成：

- 其他 gates 仍为空；
- 尚无 dedicated interrupt stack / IST；
- double fault 没有专用 handler；
- 还在使用 Limine initial stack；
- 没有 per-process fault policy；
- 没有用户态进入/退出合同。

因此 `PF:IDT:OK` 只表示 `LIDT` 已加载并且 vector 14 gate 已准备，不表示“所有中断都安全”。

## 8. 为什么 handler 不返回

触发 store 尚未完成，saved RIP 仍指向那条 store。如果 handler 什么也不修复就 `IRETQ`，CPU 会重新执行同一条指令，再次产生完全相同的 `#PF`，形成 fault loop。

可恢复 page fault 必须先改变导致失败的状态，例如分配 frame、写 page-table entry、刷新必要的 TLB 状态，然后才返回。本课尚未实现这些机制，所以最诚实的 policy 是：打印证据后 `cli; hlt`。

这与第 19 课不同：当时 `UD2` 是两字节故意陷阱，我们把 saved RIP 推进 2 来跳过它。本课不能随意跳过 store，否则会假装一次本应发生的写入已经成功。

## 9. 本课新增的最小 C 语法

跨课速查见 [Freestanding C 与内核代码参考](reference/c-basics.md)。本节只展开当前实验新增的 bit-mask 解码；指针、`struct`、`const`、`volatile` 与 output parameter 可在参考页集中回顾。

### 9.1 bit mask 解码为 `bool`

```c
report->write = (error_code & PAGE_FAULT_WRITE) != 0;
```

步骤是：

1. `&` 只保留目标 bit；
2. 与 0 比较，把“mask 值”规范化为 `false/true`。

不要直接写：

```c
report->write = error_code & PAGE_FAULT_WRITE;
```

在 C 中转换成 `bool` 也会得到正确真假，但显式 `!= 0` 更清楚地区分“原始 mask 值 `0x2`”和“解码字段 `true`”。

### 9.2 原始值和解释字段同时保留

`struct page_fault_report` 同时保存：

```c
uint64_t error_code;  /* 原始机器证据 */
bool write;           /* 从 bit 1 得到的解释 */
```

真实诊断中不能只保留解释字段，因为未来 CPU/协议新增 bit 时，原始值仍能用于重新分析。

## 10. 当前红灯为什么会亮（先不要运行）

脚手架已经完成：

1. 第 27 课 HHDM 证据仍通过；
2. 加载 vector 14 IDT gate；
3. 输出 `PF:IDT:OK` 与 `PF:TRIGGER`；
4. 对 `0x0000400000000000` 发起 supervisor data write；
5. CPU 进入 C handler，handler 读取 `CR2` 并调用 decoder。

当前 `kernel/faults.c` 中 decoder 固定返回 `false`，所以可从源码推出：

```text
HHDM:PAGE:OK      出现
PF:IDT:OK         出现
PF:TRIGGER        出现
PF:DECODE:FAIL    出现并 halt
PF:DIAG:OK        不出现
```

注意：红灯已经证明 vector 14 能到 C。它不是“没有触发 page fault”，而是“原始证据尚未被你的纯 C 函数结构化”。

## 实验前预测

先填写 `notes/06-Limine与内核主线/note-28.md`，不要运行后覆盖原答案。

### 1. 合成 error code 推演

根据 bit 表解码：

```text
address    = 0x00000000deadb000
error_code = 0x0000000000000017
rip        = 0xffffffff80001234
```

填写 report 中三个原始值与 `present/write/user/reserved_write/instruction_fetch`。提示：`0x17 = 0b10111`。

### 2. 本课真实触发的可推导结果

根据第 2、3 节已展示的触发代码，填写：

- `CR2`；
- error code；
- 五个解码字段；
- RIP 能确定的范围，以及为什么不能在实验前写死精确值。

### 3. 当前红灯

根据第 10 节写出五个 marker 哪些出现、哪些不出现，控制流停在哪里。不要把尚未打印的真实 RIP 当作预测输入。

### 4. 若 handler 直接 `IRETQ`

在 page table 未变化、saved RIP 未变化的前提下，下一步会发生什么？解释为什么本课选择 halt。

## 11. 第一次运行：确认红灯

完成预测后运行：

```sh
make inspect-page-fault
make check-page-fault
```

预期只失败在：

```text
#PF 已经到达 C
→ page_fault_decode() 固定返回 false
→ PF:DECODE:FAIL
```

若看不到 `PF:IDT:OK` 或 `PF:TRIGGER`，属于脚手架问题；若连 `HHDM:PAGE:OK` 都没有，则是旧课回归，不要修改 decoder 掩盖它。

## 12. 实验：完成一个纯 C 函数

只编辑 `kernel/faults.c` 中的：

```c
bool page_fault_decode(...);
```

按顺序：

1. `report == NULL` 时返回 `false`；
2. 原样复制 `address`、`error_code` 和 `rip`；
3. 用 `PAGE_FAULT_PRESENT` 解码 bit 0；
4. 用 `PAGE_FAULT_WRITE` 解码 bit 1；
5. 用 `PAGE_FAULT_USER` 解码 bit 2；
6. 用 `PAGE_FAULT_RESERVED_WRITE` 解码 bit 3；
7. 用 `PAGE_FAULT_INSTRUCTION_FETCH` 解码 bit 4；
8. 返回 `true`。

不要修改触发 VA、期望 error code、IDT 或 assembly bridge。

### 分级提示

<details>
<summary>提示 1：前三个字段</summary>

```c
if (report == NULL) {
    return false;
}

report->address = address;
report->error_code = error_code;
report->rip = rip;
```

</details>

<details>
<summary>提示 2：一个 bit 的完整写法</summary>

```c
report->write = (error_code & PAGE_FAULT_WRITE) != 0;
```

其余字段只替换对应 mask，不要用十进制位号写 magic number。

</details>

<details>
<summary>提示 3：`0x2` 的预期报告</summary>

```text
present=false, write=true, user=false,
reserved_write=false, instruction_fetch=false
```

</details>

## 13. 绿灯取证

实现后运行：

```sh
make check-page-fault
make check-hhdm-page
make check-physical-pages
make check-limine-handoff
```

真实 RIP 会随代码布局变化，不需要与讲义写死的地址一致；需要验证的是它位于高半 kernel，并与本次构建的 faulting store 对应。

## 观察与收束

真实 `CR2`、error code、RIP、bit 0 语义和直接 `IRETQ` 的后果，都已经在实验前预测与绿灯记录中出现，不再换一种措辞重复作答。

本课只留下一个尚未回答的新问题：`PF:DIAG:OK` 能证明什么、不能证明什么？距离“可恢复的 demand paging”还缺哪些机制？

<details>
<summary>已经先写下自己的判断或“不知道”后，再展开导师讲解</summary>

`PF:DIAG:OK` 证明的是这一次固定输入的证据链：未映射 store 产生 vector 14，IDT 把它送进 assembly/C bridge，handler 成功取得 `CR2`、error code 与 saved RIP，decoder 又把 bits 0..4 解释成预期字段。

它不能证明其他 exception vector 已安装，也不能证明 nested fault、double fault、用户态 fault 或任意 VA 都能安全处理；当前 handler 只会打印并 halt。

要恢复 demand paging，至少还缺三类机制：

1. **地址空间 policy**：判断 faulting VA 是否属于允许增长或按需加载的 VMA，并区分用户错误与 kernel bug；
2. **mapping 操作**：分配并清零 frame，创建带正确权限的 page-table entries，处理必要的 TLB invalidation；
3. **恢复与失败 policy**：成功后返回并重试 faulting instruction，失败时处理 OOM、终止进程，并在多核/并发环境中保护页表状态。

</details>

## 预测修订

在笔记中保留实验前答案，并在绿灯观察后逐条记录：

```text
原预测 → 真实结果 → 错误原因或一致证据
```

尤其不要用真实精确 RIP 覆盖实验前只能推出“位于高半 kernel”的答案。

## OS 视角（简要）

从 OS 视角看，`#PF` 不是单纯错误消息，而是虚拟内存机制的入口。匿名页按需分配、stack growth、memory-mapped file、copy-on-write 和用户非法访问，都会先通过类似的原始证据进入内核，再由 policy 决定恢复还是终止。

本课只完成“可靠分类并 panic”的最小版本。后续当我们拥有 allocator、页表映射器、进程地址空间和用户态异常策略时，同一条入口才能升级为可恢复的 virtual-memory subsystem。

## 官方与配套参考

- [Intel 64 and IA-32 SDM 下载页](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)（Volume 3A：Interrupt and Exception Handling、Page-Fault Exception）
- [AMD64 Architecture Programmer's Manual](https://www.amd.com/en/support/tech-docs/amd64-architecture-programmers-manual-volumes-1-5)（Volume 2：Exceptions and Interrupts）
- [OSTEP：Address Translation](https://pages.cs.wisc.edu/~remzi/OSTEP/vm-mechanism.pdf)

## 完成标准

- 能区分 vector 14、`CR2`、error code 和 saved RIP。
- 能把 `0x2` 解读为 supervisor data write to a non-present page。
- 能解释为什么不修复 mapping 就不能直接 `IRETQ`。
- `page_fault_decode()` 保留原始证据并解码 bits 0..4。
- `make check-page-fault` 及三项 Limine 历史回归通过。
- 笔记保留原预测、红灯、实现和绿灯证据；预测已覆盖的内容不要求在观察题中重复抄写。
