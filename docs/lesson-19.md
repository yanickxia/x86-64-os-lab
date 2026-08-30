# 第 19 课：让异常进入 C，并从 `UD2` 安全返回

## 先修知识

开始前应理解：

- 第 18 课已经建立汇编与 C 的调用边界，普通 `CALL/RET` 可以正常使用内核栈。
- `RSP=0x90000`，代码和栈都位于低 2 MiB 恒等映射中。
- IDT 决定异常发生后 CPU 把控制权交给哪个入口；上一课只解释了为什么需要它，本课第一次真正安装一个 gate。
- 普通函数的返回地址由 `CALL` 压栈；异常不是函数调用，它的返回现场由 CPU 自动保存。

权威参考：

- [Intel 64 and IA-32 Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)：Volume 3A 的 “Interrupt and Exception Handling”，以及 Volume 2 的 `UD2`、`IRET/IRETQ` 指令说明。
- [AMD64 Architecture Programmer’s Manual](https://docs.amd.com/v/u/en-US/40332_4.09_APM_PUB)：long mode 的 interrupt stack frame 与 64 位 `IRET` 对 `SS:RSP` 的保存/恢复规则。
- [MIT xv6-riscv `kernel/trap.c`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/trap.c) 与 [`kernel/trampoline.S`](https://github.com/mit-pdos/xv6-riscv/blob/riscv/kernel/trampoline.S)：不同 ISA 下同样采用“架构入口保存现场，C 代码决定策略”的分层。

本课不要求手写 IDT descriptor、不要求背 15 个 `PUSH/POP`，也不考 `IRETQ` opcode。它们是架构胶水，课程已经提供并验收。

## 本课只引入一个机制

**把一次同步 CPU 异常转化为 C 可以检查和修改的 `exception_frame`，再返回被中断的控制流。**

```text
C 调用 trigger_invalid_opcode()
          │
          ▼
       UD2（#UD）
          │ CPU 根据 IDTR 查 vector 6，并压入 RIP/CS/RFLAGS/RSP/SS
          ▼
isr_invalid_opcode（汇编：保存寄存器、对齐栈）
          │ CALL
          ▼
invalid_opcode_handler(frame)（C：决定恢复到哪里）
          │
          ▼
IRETQ → UD2 后一条指令 → 输出 R → kernel_hang
```

从这一课开始，CPU 不再只是我们启动时要满足的一组限制；异常入口会成为操作系统夺回控制权、诊断故障和实施隔离的核心通道。

## 实验输入：稍后预测会用到

下面先给出实验涉及的源码、地址和 CPU 规则。此处只阅读，**暂时不要作答，也不要运行 `make check-exception`**；读完异常机制与红灯成因后再填写预测。

### 输入 A：`kernel_main` 的完整顺序

进入 `kernel_main` 前，debug console 已收到 `HelloPTLK`：

```c
void kernel_main(void) {
    debug_putc('C');
    idt_install();
    trigger_invalid_opcode();
    debug_putc('R');
}
```

如果 `trigger_invalid_opcode()` 能返回，最后的 `R` 才会输出；`kernel_main` 随后返回汇编入口，最终停在固定的 `kernel_hang`（`RIP=0x1000e`）。

### 输入 B：本课唯一的 IDT gate

脚手架在内存中准备了 7 个、每个 16 字节的 IDT entry：

```text
vector 0..5  空，本课不处理
vector 6     present 的 ring-0 interrupt gate
             selector = 0x18（64 位内核代码段）
             handler  = isr_invalid_opcode
```

`LIDT` 装入的 limit 等于 `7 × 16 - 1 = 111 = 0x6f`。这是一张**只足够本实验使用的窄 IDT**，不是完整的 256-vector 内核 IDT。

### 输入 C：`UD2` 与 CPU 异常帧

`trigger_invalid_opcode` 当前位于 `0x10028`：

```asm
trigger_invalid_opcode:
    ud2                 ; 0x10028..0x10029，共 2 字节
    ret                 ; 0x1002a
```

`UD2` 被架构保证始终产生 invalid-opcode exception（`#UD`，vector 6）。它属于 fault：CPU 保存的 `RIP` 仍指向引发异常的 `UD2`，即 `0x10028`，而不是下一条 `0x1002a`。

`#UD` 没有 error code。64 位模式会保存完整的五项返回现场，即使这次没有发生特权级切换：

```text
exception_frame.rip     = 0x10028
exception_frame.cs      = 0x0018
exception_frame.rflags  = 异常前的 RFLAGS
exception_frame.rsp     = 异常前的 RSP
exception_frame.ss      = 异常前的 SS（当前为 0x0010）
```

汇编入口会额外保存通用寄存器，但传给 C 的指针指向上面五个由 CPU 建立的字段。本课只修改第一项 `rip`。

### 输入 D：当前红灯 handler

```c
void invalid_opcode_handler(struct exception_frame *frame) {
    debug_putc('U');

    const uint64_t fault_rip = frame->rip;
    uint64_t resume_rip = fault_rip;
    /* RED / TODO: advance resume_rip past the two-byte UD2. */

    if (resume_rip == fault_rip) {
        exception_red_hang();     /* 固定在 0x1006e */
    }
    frame->rip = resume_rip;
}
```

`fault_rip` 是只读的故障地址，`resume_rip` 是候选恢复地址。下面的判断故意比较两者：如果它们仍相同，说明恢复策略尚未实现，于是进入稳定死循环；如果 `resume_rip` 已前进，判断为假，才把它写回 CPU 异常帧。`exception_red_hang` 防止红灯不断重新执行 `UD2`、刷满输出或演化成不可诊断重启。

### 稍后要回答的问题（此处先不作答）

1. 红灯会输出什么完整字符串？为什么不会输出 `R`，最终 `RIP` 会在哪里？
2. C handler 刚进入时 `frame->rip` 是多少？要恢复到 `RET`，它必须变成多少？
3. 正确修改后，依次写出 `#UD` 发生到 `kernel_hang` 的控制流，以及完整输出。
4. IDTR.limit 为什么是 `0x6f`？这张表能否处理 vector 14 的 `#PF`？

## 1. 异常不是“程序崩了”，而是一次受控的内核入口

当 CPU 无法继续按普通语义执行时，它不能调用 C 的 `printf`，也不知道操作系统希望杀进程、补一页内存还是终止内核。硬件能做的是提供一个最小、确定的交接协议：

1. 给事件一个 vector。
2. 保存足以描述原控制流的机器状态。
3. 从操作系统事先安装的表中找到入口。
4. 跳入内核代码。

操作系统随后决定策略：

```text
#PF → 地址是否合法？按需分配、终止进程，还是 kernel panic？
#DE → 来自用户态还是内核态？发信号还是停止？
timer interrupt → 是否该抢占当前进程？
system call → 用户要求执行哪个受控服务？
```

所以 trap/exception 不是附属调试功能，而是虚拟内存、用户态隔离、系统调用和抢占调度共同依赖的控制入口。本课先用最简单的 `#UD` 建立这条主干。

## 2. exception、interrupt 和 system call 的共同点与差异

三者都会让 CPU 暂停当前控制流并进入内核，但来源不同：

| 类型 | 来源 | 与当前指令的关系 | 本课程后续用途 |
|---|---|---|---|
| exception | CPU 执行当前指令时发现 | 同步、可复现 | `#PF/#UD/#DE` 诊断与内存管理 |
| hardware interrupt | 外设/APIC | 异步 | 时钟、键盘、磁盘与抢占 |
| system call | 程序主动执行规定指令 | 同步、主动 | 用户态请求内核服务 |

`CLI` 只清除 `RFLAGS.IF`，屏蔽可屏蔽的外部中断；它不能屏蔽当前指令产生的 `#UD`。如果同步异常也能被 `CLI` 忽略，CPU 遇到无法定义结果的指令时反而无处可去。

## 3. 为什么实模式 IVT 演化成了 IDT

实模式的 Interrupt Vector Table 主要是一张 `segment:offset` 入口数组。进入保护模式和 long mode 后，CPU 还必须在交接前检查更多条件：入口是否 present、目标代码段、gate 类型、允许哪个特权级主动进入，以及是否切换到指定的 IST 栈。

因此 IDT entry 不只是一个地址，而是一道受硬件检查的门：

```text
vector 6
  → IDTR.base + 6 × 16
  → { handler offset, CS selector 0x18, type, DPL, present, IST }
  → isr_invalid_opcode
```

本课的 `idt_install()` 已填写 descriptor 并执行 `LIDT`。你只需理解角色，不需要记字段位：IDTR 定位表，vector 选择 entry，gate 决定入口与权限。

## 4. CPU 保存的是“返回现场”，不是 C 函数参数

`CALL` 只压入返回地址；异常需要保存更多状态，因为 handler 结束后必须恢复指令流和执行语境。64 位模式的 `#UD` 帧为：

```text
低地址（当前 RSP）
┌──────────────────────┐
│ RIP = 0x10028        │ ← frame 指向这里
├──────────────────────┤
│ CS  = 0x0018         │
├──────────────────────┤
│ RFLAGS               │
├──────────────────────┤
│ old RSP              │
├──────────────────────┤
│ old SS = 0x0010      │
└──────────────────────┘
高地址
```

64 位模式无条件保留旧 `RSP/SS`，使 `IRETQ` 可以完整恢复原栈；有些异常还会在低地址端额外压入 error code。后续会把“有/无 error code”等入口差异归一化为统一 trap frame。本课选择无 error code 的 `#UD`，是为了先看清最小机制。

异常入口保存所有通用寄存器，是因为异常原则上可以落在任意指令边界。C 编译器不知道自己会在这里被异步打断；如果 handler 随意破坏寄存器，恢复后原代码可能在很远的位置才表现出错误。脚手架还负责重新满足 C ABI 的栈对齐，然后才调用 `invalid_opcode_handler(frame)`。

## 5. 为什么本实验要修改保存的 `RIP`

`#UD` 是 fault，保存的 `RIP` 指向故障指令。这允许真实内核在修复原因后重试，例如缺页 handler 建好页表后重新执行原内存访问。

但 `UD2` 永远不可能通过重试成功：

```text
frame->rip 保持 0x10028
  → IRETQ
  → 再次执行 UD2
  → 再次 #UD
  → 无限循环
```

本课知道这是自己故意放置、长度明确为 2 字节的测试点，所以可以把恢复地址改成 `0x1002a`。**真实内核不能对未知的 `#UD` 一律加 2**：非法指令长度不固定，盲目跳过还可能掩盖内核损坏或攻击。真实策略通常是终止出错的用户进程，或在内核态打印现场后 panic。

## 6. `IRETQ` 为什么不是普通 `RET`

C handler 返回后，汇编入口先恢复通用寄存器，再执行 `IRETQ`。64 位 `IRETQ` 从 CPU 异常帧恢复：

```text
RIP ← frame.rip
CS  ← frame.cs
RFLAGS ← frame.rflags
RSP ← frame.rsp
SS  ← frame.ss
```

普通 `RET` 只取一个返回地址，无法同时恢复 `CS/RFLAGS/RSP/SS`。因此汇编入口不能被普通 C 函数结尾完全替代；C 决定策略，`IRETQ` 完成 CPU 规定的返回协议。

## 7. OS 视角：与 xv6 的 trap 路径对照

xv6 运行在 RISC-V，没有 IDT 和 `IRETQ`，但职责分层几乎相同：

```text
x86-64 本课                 xv6/RISC-V                 角色
IDT gate                    stvec                      找到 trap 入口
isr_invalid_opcode          trampoline/kernelvec      保存寄存器、建立 C 环境
exception_frame             trapframe                  描述被打断的机器状态
invalid_opcode_handler      usertrap/kerneltrap        C 代码选择处理策略
IRETQ                       sret                       恢复现场并返回
```

寄存器名与帧格式属于架构，**“入口胶水 → 统一状态 → C 策略 → 特殊返回”**属于操作系统共同结构。以后处理 `#PF`、系统调用和时钟中断时会继续扩展这条路径，而不是重新发明另一套控制流。

## 红灯机制（先不要运行）

当前 handler 能收到 `#UD` 并输出 `U`，但 `resume_rip` 仍等于故障指令地址。安全分支会因此进入固定的 `exception_red_hang`，阻止 `IRETQ` 回到同一条 `UD2` 形成无限异常循环。于是异常入口已经工作，恢复策略尚未完成。

这里先理解保存 `RIP`、红灯 guard 和返回路径，不运行命令，也不查看真实输出。

## 实验前预测

现在已经读完 IDT、异常帧、`IRETQ` 和红灯成因。回到前面的“稍后要回答的问题”，
在第一次运行 `make check-exception` 前把答案写入 `notes/05-C内核与Bootloader毕业/note-19.md`；
错误预测原样保留。

## 运行真实红灯

运行：

```sh
make inspect-exception
make check-exception
```

当前 handler 已收到 `#UD` 并输出 `U`，随后因恢复地址未改变而停在红灯循环：

```text
exception check: #UD reached the C handler but did not resume
exception check: expected 'HelloPTLKCUR', got 'HelloPTLKCU'
exception check: advance the saved RIP past the two-byte UD2 in kernel/interrupts.c
exception check: expected execution to return and park at RIP=0x1000e
exception check: actual RIP=0x000000000001006e
```

这是一盏干净红灯：

- `U` 证明 IDT、vector 6、汇编入口和 C handler 已经工作。
- 没有 `R` 证明控制流尚未越过 `UD2`。
- `RIP=0x1006e` 证明它停在预设的 `exception_red_hang`，不是 triple fault 或随机死机。

## 练习

打开 `kernel/interrupts.c`，只完成一个 TODO：让局部变量 `resume_rip` 指向两字节 `UD2` 后的地址。

约束：

- 只修改 `RED / TODO (lesson 19)` 下方。
- 不直接写固定地址 `0x1002a`；根据 `frame->rip` 和已知指令长度计算，避免链接布局变化后失效。
- 不修改 IDT、汇编入口、`exception_red_hang`、期望字符串或检查器。
- 不删除安全分支；正确更新 `resume_rip` 后，编译器会证明条件恒为假并优化掉红灯调用。

## 绿灯与取证

完成后运行：

```sh
make inspect-exception
make check-exception
make check-c-kernel
make check-kernel-entry
```

预期关键证据：

```text
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x... limit=0x006f, output='HelloPTLKCUR'
C-kernel check passed: assembly called kernel_main and output begins 'HelloPTLKC'
```

完成后的 C handler 很可能被编译成直接修改内存中的保存 `RIP`，而不是保留源码里的局部变量。记录实际反汇编，不要求与某个固定机器码相同。

## 观察题

1. 用地址串起 `UD2 → #UD → C handler → IRETQ → RET → kernel_hang`，说明 `U` 和 `R` 分别在哪一步输出。
2. 为什么 `RFLAGS.IF=0` 没有阻止 `#UD`？exception 与可屏蔽硬件 interrupt 的来源有何不同？
3. 为什么异常汇编入口要保存寄存器并重新对齐栈，不能像普通 C 调用一样直接假设 ABI 已经满足？
4. 为什么“把保存 RIP 加 2”只适合这个明确的测试点？真实内核遇到未知 `#UD` 应如何区分用户态与内核态策略？
5. 当前 IDT 为什么仍不完整？如果现在触发 vector 14 的 `#PF`，`IDTR.limit=0x6f` 会带来什么后果？

## 完成标准

- 实验前四项预测在第一次运行红灯前完成；错误预测原样保留。
- 只修改 `kernel/interrupts.c` 中的单个 TODO。
- `make check-exception` 验证输出 `HelloPTLKCUR`、IDTR limit `0x006f` 和最终 `RIP=0x1000e`。
- 能解释 CPU 异常帧、保存 `RIP`、C handler 与 `IRETQ` 各自的职责。
- 能说明同步 exception 不受 `CLI` 屏蔽，以及本课跳过 `UD2` 为什么不是通用 `#UD` 策略。
- 第 0–18 课的启动、分页、ELF 和 C 入口检查全部回归通过。
