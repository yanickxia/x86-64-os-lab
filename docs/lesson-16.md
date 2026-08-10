# 第 16 课：换一颗 CPU，操作系统还剩下什么

这一课横向比较三类常见的 64 位应用处理器架构：

- 我们正在学习的 **x86-64**。
- xv6 与 MIT 6.1810 使用的 **RV64 RISC-V**，重点是 S-mode 与 Sv39。
- 服务器、手机和 Apple Silicon 所属的 **AArch64 / Arm A-profile**，不是没有 MMU 的 Cortex-M 微控制器。

本章不写代码、不增加命令，也不设置红灯或绿灯。目标是分清两件事：哪些步骤只是 x86 的历史路径，哪些问题换成任何 CPU 都必须由操作系统解决。

## 1. 先分清 ISA、平台和 ABI

讨论“CPU 架构不一样”时，常把三个层次混在一起：

1. **ISA（Instruction Set Architecture）**：指令、寄存器、特权级、异常和地址转换等 CPU 与软件之间的契约。
2. **平台（platform）**：固件、内存布局、中断控制器、定时器、串口和设备发现方式。两台同为 ARM64 的机器，平台仍可能完全不同。
3. **ABI（Application Binary Interface）**：函数参数放在哪些寄存器、谁保存哪些寄存器、栈如何对齐、系统调用号放在哪里、ELF 如何组织。

例如：

- `ECALL` 是 RISC-V ISA 的指令，但“系统调用号放 `a7`”是具体 OS ABI 的约定。
- `SVC` 是 AArch64 ISA 的指令，但“Linux 把系统调用号放 `x8`”不是 CPU 强制规定。
- x86-64 的 `SYSCALL` 只负责跨越特权边界；参数寄存器和 syscall number 仍由 ABI 决定。

因此，移植操作系统不是简单地把一条 x86 指令替换成一条 RISC-V 指令，而是重新实现 ISA、平台和 ABI 三层边界。

## 2. 三种架构都必须解决的同一组问题

无论指令长什么样，一个支持多进程的通用操作系统都要回答：

| 操作系统问题 | CPU 至少要提供的机制 |
|---|---|
| 用户程序不能任意改内核 | 特权级与受保护指令 |
| 每个进程看到自己的地址空间 | 页表、权限位和 TLB |
| 系统调用怎样进入内核 | 同步异常/特权调用入口 |
| 缺页、除零和设备中断怎么办 | trap/exception 入口与可恢复现场 |
| 如何切换线程 | 可保存和恢复的寄存器状态 |
| 多核如何安全共享数据 | 原子指令与内存顺序规则 |
| 如何访问磁盘、网卡和定时器 | MMIO/端口 I/O、设备中断和平台描述 |
| 内核如何获得第一份运行环境 | 固件或 bootloader 的交接契约 |

这些问题就是操作系统的共同骨架。A20、GDT、`satp`、`VBAR_EL1` 都只是某种架构给出的具体答案。

## 3. 一张总对照表

下表只列最常见的 OS 用法，不穷举虚拟化、安全世界和所有可选扩展。

| 主题 | x86-64 | RV64 RISC-V | AArch64 |
|---|---|---|---|
| 常规用户/内核级别 | ring 3 / ring 0 | U-mode / S-mode | EL0 / EL1 |
| 更高层固件/虚拟化 | SMM、VMX root 等独立机制 | M-mode；可选 HS/VS | EL2 hypervisor、EL3 secure monitor |
| 页表根 | `CR3` | `satp` | `TTBR0_EL1` / `TTBR1_EL1` |
| 常见页表 | 4 级，4 KiB 基页；可选 5 级 | Sv39 3 级；另有 Sv48/Sv57 | 粒度和 VA 范围可配；常见 4 KiB、4 级 |
| trap 入口 | IDTR 指向 IDT descriptor table | `stvec` 保存入口地址/模式 | `VBAR_EL1` 指向固定布局的 vector table |
| trap 原因与地址 | vector、error code，缺页地址在 `CR2` | `scause`、`stval` | `ESR_EL1`、`FAR_EL1` |
| 保存的返回位置 | 硬件压入的 `RIP/CS/RFLAGS...` | `sepc` | `ELR_EL1`，状态在 `SPSR_EL1` |
| 特权调用/返回 | `SYSCALL/SYSRET` 或 `INT/IRETQ` | `ECALL/SRET` | `SVC/ERET` |
| TLB 维护 | `INVLPG`、`INVPCID`、重载 `CR3` | `SFENCE.VMA` | `TLBI`，并配合所需的 `DSB/ISB` |
| 外部中断控制器 | Local APIC / I/O APIC / MSI | PLIC，或较新的 AIA；定时器可能经 SBI | GIC |
| 每 CPU 指针常见做法 | `GS.base` | `tp` | `TPIDR_EL1` |
| 设备访问 | port I/O 与 MMIO 都存在 | 主要使用 MMIO | 主要使用 MMIO |

名字差别很大，但每一列都能找到“页表根、异常入口、返回 PC、故障原因、TLB 刷新”这组角色。

## 4. 启动路径：差异最大，也最容易误认为是 OS 本质

### x86-64：背着兼容历史走到 long mode

我们已经亲手经历：reset vector → BIOS → 16 位实模式 → A20 → GDT → 32 位保护模式 → PAE/page tables → long mode。

这条路之所以长，主要来自 x86 对早期软件和执行模式的兼容。A20、实模式分段以及通过 GDT/far jump 切换模式，都不是“操作系统必然如此”，而是“从兼容的 x86 reset 状态启动时如此”。现代 x86 UEFI 可以替 loader 做掉其中一部分，但 CPU 的历史结构仍存在。

### RISC-V：架构干净，但平台仍需要固件

RISC-V 没有实模式、A20 或 GDT。M-mode 是最高且唯一强制实现的特权模式；常规 Unix 内核通常运行在 S-mode。常见启动栈是：

```text
硬件/早期固件 → M-mode SBI firmware（例如 OpenSBI）→ S-mode 内核
```

SBI 把启动其他 hart、定时器、IPI 等平台功能抽象成 S-mode 可以调用的接口。以 Linux 为例，固件进入内核时还会提供 boot hart id、Device Tree/ACPI 等信息；这不是 RISC-V 单条指令能解决的事情。

### AArch64：异常级模型清晰，平台交接同样重要

AArch64 使用 EL0–EL3。通常应用在 EL0、内核在 EL1、hypervisor 在 EL2、secure monitor/firmware 在 EL3；EL2 和 EL3 是否实现及如何使用取决于平台。固件会完成更早期的 SoC 初始化，再按平台协议把内核放到 EL1 或 EL2，并传入 Device Tree 或 ACPI 等硬件描述。

所以，RISC-V/ARM64 看起来“开机更快进入内核”，不是因为没有 boot 问题，而是因为更多问题被明确放在 firmware/platform contract 一侧。

## 5. 特权级不同，隔离目标相同

三种架构最常见的内核结构都可以画成：

```text
用户程序：低特权级
       │ syscall / exception / interrupt
       ▼
内核：高特权级
       │ return-from-exception
       ▼
用户程序继续执行
```

- x86 有四个 ring，但现代通用 OS 主要使用 ring 0 和 ring 3；ring 1/2 很少参与普通进程隔离。
- RISC-V 用 U/S/M 表达应用、OS 和最高层机器固件。SBI 正好位于 S-mode 内核与更高特权软件之间。
- AArch64 用 EL0/EL1/EL2/EL3 分出应用、OS、hypervisor 和 secure firmware。

它们不是严格的一一对应。例如 M-mode 不等于 x86 ring 0：M-mode 常驻固件可以位于 S-mode OS 之上；ARM EL3 还涉及安全状态。但从内核设计看，最关键的问题一致：用户态不能写页表、关中断或直接控制设备，必须通过受控入口请求内核服务。

## 6. Trap：硬件保存多少，剩下多少交给汇编入口

一场 trap 的共同流程是：

```text
事件发生
  → CPU 记录最小返回状态并提高/确认特权级
  → 根据架构入口找到少量汇编代码
  → 汇编保存通用寄存器，构造统一 trap frame
  → C handler 根据原因处理
  → 恢复现场并执行架构专用返回指令
```

差异在“CPU 自动做多少”：

- **x86-64**：CPU 根据 IDT descriptor 找入口，自动压入一部分返回现场；发生特权级切换或使用 IST 时还能切换栈。部分异常还会压入 error code。内核入口必须把不同硬件 frame 统一起来。
- **RISC-V**：CPU 把返回 PC、原因和附加值写入 `sepc/scause/stval`，更新 `sstatus` 后跳到 `stvec`。它不会自动保存全部通用寄存器，也不会替 S-mode 选择一套完整内核栈，xv6 因而在 trampoline 中显式完成这些工作。
- **AArch64**：CPU 根据异常来自哪个 EL、使用哪个 SP 以及异常类型，选择 `VBAR_EL1` 中固定偏移的 vector entry；返回位置和旧状态进入 `ELR_EL1/SPSR_EL1`。通用寄存器仍由入口代码保存。

这解释了为什么不同架构的 `trap.S` 差别很大，而进入 C 之后的 `page_fault()`、`syscall()`、`timer_tick()` 又可以拥有相似结构。

## 7. 分页：表的形状不同，地址空间抽象相同

页表最终都在实现：

```text
virtual address
  → 按若干级 index 查 page-table entry
  → 检查 present/valid、user、read/write/execute 等权限
  → 得到 physical page + page offset
```

### 表结构

- 当前 x86-64 实验是 `PML4 → PDPT → PD`，叶子用 2 MiB large page；正式内核通常还会加入 PT，形成 4 KiB 页的四级路径。
- xv6 使用 Sv39：39 位有效虚拟地址、三级页表，每级 index 9 位，page offset 12 位。
- AArch64 的 translation granule 可以选择 4 KiB、16 KiB 或 64 KiB，页表级数随 granule 和配置的虚拟地址范围变化；“ARM64 永远四级”并不成立。

### 切换地址空间

- x86 通常切换 `CR3`，可结合 PCID 减少不必要的 TLB 丢失。
- RISC-V 写 `satp` 选择页表根和 ASID，并按要求执行 `SFENCE.VMA`。
- AArch64 使用 `TTBR0_EL1/TTBR1_EL1` 和 ASID；修改映射后使用 `TLBI`，并遵守架构要求的 barrier 顺序。

寄存器和 PTE 编码不能复用，但 OS 上层仍然在管理同一种对象：`address_space`、VMA、物理页、权限和缺页状态。

## 8. 系统调用与上下文切换

### 系统调用

`SYSCALL`、`ECALL`、`SVC` 的共同作用只是制造一个受控的特权转换。CPU 不知道 `read`、`fork` 或 `mmap` 是什么；系统调用表、参数校验、用户指针检查和返回值语义都是 OS 定义的。

因此一个可移植内核通常把入口拆成两层：

```text
arch-specific entry
  保存寄存器、识别系统调用号、形成统一 trap frame
        │
        ▼
portable syscall dispatcher
  查表、验证参数、调用文件系统/进程/内存子系统
```

### 上下文切换

调度器的策略——选哪个 runnable thread——基本与 ISA 无关；真正执行切换的十几条汇编高度相关：

- 保存旧线程必须保留的通用寄存器和 stack pointer。
- 恢复新线程的寄存器和 stack pointer。
- 必要时切换页表根、用户态返回现场、浮点/向量状态与每 CPU 状态。

这也是为什么 xv6 的 scheduler 思路可以搬到 x86-64，而 `swtch.S` 不能原样复制。

## 9. 多核与内存模型：最危险的“在 x86 上能跑”

x86-64 通常提供比 RVWMO 和 Arm 内存模型更强的普通内存顺序保证。这会制造一个常见陷阱：缺少同步的并发代码可能在 x86 测试中“看起来正常”，移植到 RISC-V/ARM64 后才暴露重排序问题。

但这不表示 x86 可以不用同步：编译器也会重排，x86 也允许某些架构可见的顺序差异，设备 MMIO 更有专门规则。正确做法是按语言和内核内存模型使用：

- 原子 read-modify-write。
- acquire/release。
- spinlock、mutex 等同步原语。
- 必要的 memory barrier 和 I/O barrier。

架构后端再把这些抽象映射为 x86 的 locked operation/fence、RISC-V 的 AMO/LR-SC/fence、AArch64 的原子或 exclusive 指令与 DMB/DSB/ISB。

## 10. xv6 RISC-V 概念怎样翻译到本课程

不是逐字替换，但可以建立角色映射：

| xv6 / RISC-V | x86-64 中最接近的角色 | 注意 |
|---|---|---|
| `satp` | `CR3` 加分页模式控制 | x86 的模式开关分散在 `CR0/CR4/EFER` |
| `stvec` | IDTR + IDT entries | x86 入口是 descriptor table，不只是一个地址寄存器 |
| `sepc` | trap frame 中保存的 `RIP` | x86 通常由硬件压栈 |
| `scause` | IDT vector + error code | 编码和异常分类不同 |
| `stval` | 缺页时的 `CR2` 等附加状态 | 只有部分 trap 能直接对应 |
| `sret` | `IRETQ`，或特定 syscall 路径的 `SYSRET` | 返回现场格式不同 |
| `sfence.vma` | `INVLPG/INVPCID` 或受控重载 `CR3` | 刷新粒度和顺序规则不同 |
| `sscratch` / `tp` | entry convention、`GS.base` | 常用于 trap/per-CPU 数据，但机制不同 |

以后阅读 xv6 时，不要问“这一行 RISC-V 汇编怎么翻成 x86”；先问“它在保存哪种状态、维持哪个内核不变量”。

## 11. 一个内核中哪些部分应该可移植

可以把源码树想象成：

```text
kernel/
  arch/x86_64/     boot · page table encoding · trap entry · context switch
  arch/riscv64/    boot · page table encoding · trap entry · context switch
  arch/arm64/      boot · page table encoding · trap entry · context switch

  mm/              page allocator · address-space policy · COW
  sched/           runnable queues · scheduling policy
  fs/              VFS · inode · buffer cache
  proc/            process lifecycle · wait/exit
```

现实中边界不会如此完美：cache、TLB、NUMA、interrupt topology 和 DMA 会向上渗透。但这是一个很好的设计目标——让架构相关代码集中在明确边界，而不是散落在整个内核。

## 12. 三个最终结论

1. **x86 前 14 课大部分是平台建立过程，不等于操作系统的全部。** A20、实模式和 GDT 演化是 x86 特有；特权、分页、trap 和原子同步不是。
2. **RISC 与 CISC 的差别不会改变 OS 的核心抽象。** 指令编码和入口代码会变，进程、地址空间、调度、锁、文件和系统调用仍然存在。
3. **学习另一架构最有效的方法是做角色映射。** 找到“页表根、trap vector、返回 PC、fault cause、TLB fence、per-CPU pointer”，再去看具体寄存器名。

下一课开始 C。汇编不会消失，但会收缩到 ABI 入口、trap entry、上下文切换和少量原子/寄存器操作；操作系统的主体将逐步转移到可读、可组织的 C 代码。

## 官方参考

- [Intel 64 and IA-32 Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [RISC-V Privileged Architecture：Privilege Levels](https://docs.riscv.org/reference/isa/priv/priv-intro.html#_privilege_levels)
- [RISC-V Supervisor-Level ISA：stvec、satp、Sv39 与 SFENCE.VMA](https://docs.riscv.org/reference/isa/priv/supervisor.html)
- [RISC-V Supervisor Binary Interface Specification](https://docs.riscv.org/reference/sbi/_attachments/riscv-sbi.pdf)
- [Arm AArch64 Exception Model](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/Exception%20model.pdf)
- [Arm Architecture Reference Manual for A-profile](https://developer.arm.com/documentation/ddi0487/latest)
- [Linux：RISC-V Kernel Boot Requirements](https://cdn.kernel.org/doc/html/latest/arch/riscv/boot.html)
- [Linux：Booting AArch64 Linux](https://cdn.kernel.org/doc/html/latest/arch/arm64/booting.html)
