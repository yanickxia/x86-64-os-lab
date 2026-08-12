# x86-64 操作系统学习路线

## 加速轨道：从启动细节转向操作系统主线

第 0–13 课已经建立了足够可信的 x86-64 启动基础：实模式、保护模式、分页、long mode、磁盘加载和独立载荷都已有机器证据。从第 14 课起采用加速轨道：

- linker、ABI 和少量架构入口代码作为**桥接基础设施**，由课程提供可工作的脚手架与检查，不再逐字节手写。
- 汇编只在异常/中断入口、上下文切换和系统调用边界出现；必需部分会给模板，学习重点是保存的机器状态和内核不变量，而非 opcode 记忆。
- CPU 厂商手册用于查证行为，不再把每个寄存器位或编码变体都扩展成独立章节。
- 必做主线直接转向：C 内核 → 异常 → 物理内存 → 虚拟内存 → 用户态/系统调用 → 进程与调度 → 并发 → 文件系统。
- boot、ELF 字段、descriptor 编码和启动设计取舍保留为可选复盘材料；只有实际影响 OS 设计或调试时才回看。

目标是把时间花在操作系统抽象、状态转换、资源管理、隔离与并发上，同时保留一条足够可靠的 x86-64 平台证据链。

第 20–24 课是自制 bootloader 的明确毕业阶段：依次完成多扇区加载、stage 1 / stage 2、E820 `boot_info`、ELF `PT_LOAD`、`.bss`、内核栈与 ABI handoff。第 24 课逐项取证并列出有意不实现的生产功能；第 25 课先介绍 Limine bootloader/protocol，再逐项映射自己的交接合同，并以高半 ELF + memory-map response 建立新内核基线。这样 Limine 是成熟实现的替换，而不是用来跳过未讲清的启动缺口；第 26 课起从物理页 ownership 正式进入 OS 主线。

默认节奏是每周 6-8 小时，共约 20-24 周。实际进度以“能证明掌握”为准，不追赶日历。

## 资源如何分工

- OSTEP 是理论主线。按 Virtualization、Concurrency、Persistence 三部分选读，并完成少量模拟题。
- MIT 6.1810/xv6 是设计参照。阅读相应章节与 lab 思路，再把 RISC-V 机制翻译成 x86-64，不并行重做整门课。
- CS162/Pintos 用于借鉴测试、设计文档和工程拆分，重点放在线程、用户程序、虚拟内存和文件系统阶段。
- Intel SDM、AMD64 Architecture Programmer's Manual 和 x86-64 psABI 是硬件与 ABI 的权威来源。
- OSDev Wiki 是检索入口；关键寄存器位、描述符格式和异常语义必须回到 Intel/AMD 手册核对。
- Writing an OS in Rust 用来辅助理解 x86-64、异常和自动化测试；本课程主实现使用 C 和汇编。
- The Little Book About OS Development 只选读串口、描述符、中断和用户态思路。它以旧式 32 位 x86 为主，不作为实现基线。
- 恐龙书和 Modern Operating Systems 作为参考书，不要求顺序通读。

## 阶段与可验证里程碑

### 0. 建立可信实验环境（1 周）

- 区分 host、target、guest；掌握交叉编译器、链接器、反汇编器、模拟器和调试器各自的职责。
- 能从 ELF、节、符号、反汇编和寄存器状态解释一个构建产物。
- 里程碑：工具链自检通过，并能说明为什么 Apple Silicon 可以构建和运行 x86-64 裸机代码。

### 1. 从复位到第一条自己的指令（2 周）

- BIOS 启动扇区、实模式地址、A20、GDT、保护模式。
- 手写最小启动扇区；使用 QEMU debug console 和 GDB 观察 `CS:IP`。
- 里程碑：逐条证明 16 位代码如何进入 32 位保护模式。

### 2. 进入长模式并建立 C 运行环境（2-3 周）

- 四级页表、CR0/CR3/CR4、EFER、恒等映射与高半内核。
- ELF 链接脚本、SysV x86-64 ABI、栈对齐、清零 `.bss`。
- 里程碑：64 位 C 内核打印启动信息，GDB 能验证页表和调用栈。

### 3. 异常、中断与时间（2-3 周）

- GDT/TSS/IDT、异常帧、PIC/APIC、定时器、串口。
- 里程碑：可控触发并诊断除零、非法指令和缺页异常；定时器持续工作。

### 4. 物理与虚拟内存（3 周）

- OSTEP 地址空间、地址转换、分页、TLB 与页面替换相关章节。
- xv6 page-table、lazy allocation、copy-on-write 作为比较实验。
- 里程碑：页帧分配器、内核地址空间和按需映射均有不变量检查与测试。

### 5. 用户态边界（2-3 周）

- Ring 3、系统调用、异常返回、用户指针验证、ELF 用户程序加载。
- 对照 xv6 traps/syscall 和 CS162 user programs。
- 里程碑：第一个用户程序通过系统调用输出并安全退出。

### 6. 进程、线程与调度（3 周）

- OSTEP CPU virtualization 与 concurrency；锁、条件变量、睡眠/唤醒。
- 对照 xv6 scheduling/locking 和 CS162 threads。
- 里程碑：抢占式调度、阻塞唤醒和并发压力测试通过。

### 7. Unix 抽象与持久化（3-4 周）

- 文件描述符、管道、VFS、块缓存、inode、目录、崩溃一致性。
- 对照 xv6 file system、OSTEP persistence 和 CS162 file system。
- 里程碑：用户程序可进行 `open/read/write/close/fork/exec/wait` 的最小闭环。

### 8. 进阶专题（按兴趣）

- SMP、APIC、每 CPU 数据、内存序；virtio 块设备/网络；性能分析。
- 里程碑：双核运行并通过并发测试，或完成一个可靠的 virtio 驱动。

## 核心资料

- [MIT 6.1810 (2025)](https://pdos.csail.mit.edu/6.S081/2025/schedule.html)
- [OSTEP](https://research.cs.wisc.edu/wind/OSTEP/)
- [Berkeley CS162](https://rise.cs.berkeley.edu/course/cs162-operating-systems-systems-programming/)
- [Writing an OS in Rust](https://os.phil-opp.com/)
- [The Little Book About OS Development](https://littleosbook.github.io/)
- [OSDev Wiki: Getting Started](https://wiki.osdev.org/Getting_Started)
- [Intel Software Developer Manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [AMD64 Architecture Programmer's Manual, Volume 2](https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2)
- [x86-64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI)
- [QEMU GDB usage](https://www.qemu.org/docs/master/system/gdb.html)
- [Limine](https://github.com/limine-bootloader/limine)
