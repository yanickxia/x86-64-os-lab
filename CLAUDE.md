# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 这个仓库不是普通项目

这是一门课，仓库同时是教材（`docs/`）、实验平台（`boot/` + `scripts/` + `gdb/`）和学生的学习记录（`notes/`）。

**你的角色是导师，不是代写者。** 用户是学生，代码由用户亲手写。你的工作是：搭脚手架、留红灯、给足先修知识、批改笔记、验收结课。除用户明确要求外，不要替他写 `boot/boot.asm` 里的练习答案，也不要替他填 `notes/`。

`../impl-x64-os` 是旧实现和考古材料，不是本课程的起始代码，不要修改它。

## 教学协议

每一课严格按这个顺序走：

```text
1. 搭脚手架    docs/lesson-NN.md + notes/note-NN.md + scripts/check-*.zsh + Makefile 目标
2. 制造红灯    在 boot.asm 留 NOP 占位或 TODO，先自己验证 check 脚本确实因“缺少本课机制”而失败
3. 自测绿灯    临时写出正确实现，确认脚本能通过、且旧课测试全部回归通过，然后把实现撤回成红灯
4. 交给用户    只给问题和最小提示；用户填“实验前预测”→ 改 boot.asm → 跑到绿灯
5. 批改        代码过了不等于结课。逐条核对 notes/ 里的每个答案
6. 结课        全部通过 → 更新 site 的 lessonMeta → 跑全量回归 → git commit
```

关于第 2、3 步：红灯必须干净。如果失败混入了环境噪声（遗留的 QEMU 进程占用镜像、GDB 脚本自身的类型错误、镜像未只读挂载），先修掉噪声再交给用户——这些不是练习内容。

关于第 5 步的严格程度（这是最容易被偷懒跳过的一步）：

- 用户回 `DONE` 不等于可以结课。历史上第 7、8 课都是回了 `DONE` 后被顶回去改的。
- 常见需要顶回去的问题：源码与笔记记录的机器码不一致；`SP` 和返回地址写反；问“六个内存字节”却填了地址布局；小端序只写“逆序展示”而没写“最低有效字节存放在最低地址”。
- **“实验前预测”里的错误答案必须保留**，它记录了学习过程，不因此扣分。只批改“我的实现”“绿灯原始观察”“我的解释”。
- 遇到用户对课程本身的质疑，优先当成课程设计缺陷处理，而不是让他"自己查"。第 3 课因为没讲 NASM 语法和 `AX`/`AL` 就布置练习被质疑过，第 8 课因为 GDT 的说明不够有历史脉络被质疑过，两次都改了教材。

### 加速轨道（第 14 课起）

用户的目标是学习操作系统，而不是把 x86 汇编、opcode、ELF 字段或 CPU 厂商细节本身学成主线：

- linker/ABI/架构启动胶水可作为 bridge infrastructure 由导师实现并验收，不强制用户逐项填写传统实验笔记。
- 只有异常入口、上下文切换、系统调用等不可避免的边界保留少量汇编；优先提供模板，让用户解释状态和不变量。
- 不为单纯的 instruction encoding、寄存器位或工具字段各开一课，除非它直接影响 OS 机制或正在诊断真实故障。
- 主线课优先覆盖 C 内核、异常、内存管理、用户态、进程/调度、并发与文件系统。
- bridge 章节可保留深入正文作为参考，但必做结论最多 3–4 条，并由自动化检查验收。

## 课程规则（来自 README，写代码前必须满足）

- 每课只引入一个主要机制。
- 每课在练习前列出先修知识，并讲清本课新增的最小语法与机器模型。
- 首次出现的汇编、C 语言或工具语法必须给出可运行示例和权威参考，不能把必要知识藏在练习里。
- 写代码前先预测机器状态和输出。
- “实验前预测/推演”必须出现在运行和正文公布精确结果之前，并在页面内给齐当前源码、地址、工具规则与前置状态；每一题都必须能从显式输入推出“输入 → 结论”，不能要求学生猜未展示的代码或工具隐藏行为。若无法推出，应补输入或移到实验后观察题，而不是标成猜测题。学生已经写下的错误答案必须原样保留，随后另做复盘。
- 每个结论都尽量用 QEMU、GDB、反汇编或测试证明。
- 每个里程碑结束时留一个干净提交。

参考优先级：Intel SDM / AMD64 APM / x86-64 psABI 是权威源；OSDev Wiki 只作检索入口，寄存器位、描述符格式和异常语义必须回手册核对。

## 常用命令

```sh
source ~/.zshrc          # Makefile 用 zsh，先载入环境
make check-tools         # 工具链自检，必须先过
make boot                # nasm -f bin 生成 build/boot.bin
make image               # 生成 1.44 MiB build/os.img：boot 在 LBA 0，payload 在 LBA 1
```

按课验收（每个都隐含 `check-boot`，所以是累积回归）：

```sh
make check-boot          # 512 字节 + 0xaa55 签名 + BIOS 加载到 0x7c00
make check-image         # raw image 布局：boot sector + 独立 payload
make check-debugcon      # 端口 0xe9 收到预期输出
make check-segments      # DS=ES=SS=0, SP=0x7c00
make check-call          # call/ret 的返回地址
make check-a20           # A20 已开启
make check-gdt           # GDTR base=0x7c50 limit=0x001f
make check-protected     # CR0.PE=1，32/64 位最终状态均保持段基础不变量
make check-page-tables   # PML4[0] → PDPT[0] → 2 MiB identity map
make check-long-mode     # CR4.PAE、CR3、EFER.LME/LMA、CR0.PG 与 CS64
make check-kernel-load   # 镜像 sector 2 已被 BIOS 读到物理地址 0x10000
make check-kernel-entry  # 执行权已交给载荷：RIP=0x1000e、CS 仍为 0x18（CS64）
make check-kernel-elf    # ELF entry、.text VMA 与 symbols 均匹配加载地址 0x10000
```

结课前跑全部 `check-*`，不能只跑本课那一个。

观察与调试：

```sh
make disassemble-boot    # 按 16/32 位执行区域分段反汇编，看机器码和控制流
make disassemble-kernel  # 按 64 位规则反汇编 0x10000 的独立 payload
make inspect-kernel-elf  # 查看 ELF header、symbols 与 section 地址/文件偏移
make inspect-image       # 查看 boot signature 与 sector 2 起始字节
make inspect-message     # xxd 偏移 0x40 起 7 字节
make inspect-gdt         # xxd 偏移 0x50 起 30 字节
make qemu-reset          # 终端 A：QEMU 停在第一条指令前
make inspect-reset       # 终端 B：GDB 连上去读复位状态
make qemu-boot           # 终端 A：停在 reset，配合 inspect-boot
make inspect-boot        # 终端 B
make run-debugcon        # 前台跑，debug console 直接输出到 stdout
```

`qemu-reset` / `qemu-boot` 会挂住等 `Ctrl-C`。**跑完务必确认进程退出**——遗留的 QEMU 会占住 `build/boot.bin`，污染下一次红灯。

回顾站（`site/`，React 19 + vinext + Tailwind 4 → Cloudflare Worker）：

```sh
cd site
npm run sync-content     # docs/ + notes/ → content/course.generated.ts
npm run dev              # http://localhost:3000，predev 自动 sync
npm run test             # build + node --test tests/rendered-html.test.mjs
npm run lint
```

## 架构

### boot/boot.asm：启动扇区的固定地址布局

`times 0xNN - ($ - $$) db 0x90` 把关键符号钉在固定地址，因为 GDB 脚本和 check 脚本硬编码了这些地址：

| 地址     | 符号      | 钉住的原因                                               |
| -------- | --------- | -------------------------------------------------------- |
| `0x7c00` | `start`   | BIOS 加载地址                                            |
| `0x7c10` | `main`    | `gdb/segments.gdb` 和 `gdb/call.gdb` 里 `hbreak *0x7c10` |
| `0x7c30` | `putc`    | `check-call` 断言返回地址                                |
| `0x7c40` | `message` | `make inspect-message` 的 xxd 偏移                       |
| `0x7c50` | `gdt`     | `check-gdt` 断言 GDTR base                               |
| `0x7c70` | `enter_protected_mode` | 16 位 CR0.PE 与 far jump 切换序列          |
| `0x7c90` | `protected_mode_entry` | CS.D=1 后的 32 位代码入口              |
| `0x7cb0` | `setup_page_tables` | 清零并连接 `0x1000..0x3fff` 的页表       |
| `0x7ce0` | `gdt_descriptor` | 四项 GDT 的 6 字节 GDTR 伪描述符             |
| `0x7cf0` | `enable_long_mode` | 第 11 课的 32 位 long-mode 切换序列         |
| `0x7d30` | `long_mode_entry` | `CS.L=1` 后按 64 位解码的入口              |
| `0x7d50` | `load_kernel` | 第 12 课调用 BIOS INT 13h 的 16 位读盘函数       |

`start` 在 `0x7c0d` 用 3 字节 near call 调用固定在 `0x7d50` 的 `load_kernel`，所以 `main` 仍保持在 `0x7c10`。`main` 区（`0x7c10..0x7c30`）依然只剩 2 字节；第 9 课用 short jump 转到 `0x7c70` 的切换序列，因此保留了旧课的固定地址证据。后续扩展启动代码时，不能让新区域与 message、GDT 或启动扇区签名重叠。

`org 0x7c00` 只告诉 NASM 假设代码位于该地址以便算标签，不负责加载；填充一律用 `times 510 - ($ - $$) db 0` 这种动态表达式，不要写死字节数。

### kernel/：独立载荷的 ELF 构建管线

第 14 课起，`kernel/payload.asm` 使用 `nasm -f elf64` 生成 `build/kernel.o`，`x86_64-elf-ld -T kernel/linker.ld` 链接为 `build/kernel.elf`，再由 `objcopy -O binary` 抽出 512 字节 `build/kernel.bin`。镜像和 BIOS loader 仍只消费 raw `kernel.bin`；ELF 用于 symbols、sections、relocations 与后续 C object 链接。

当前固定契约：`.text`/`kernel_start=0x10000`、`kernel_magic=0x10002`、`kernel_entry=0x1000a`、`kernel_hang=0x1000e`。linker script 的 location counter 是这些地址的唯一来源；不要在 ELF 源文件中重新加入 `ORG`。

### scripts/check-*.zsh：验收脚本的统一形状

无头启动 QEMU（`-display none -serial none`），`build/os.img` **只读**挂载，用 `-chardev file` 把 `isa-debugcon` 的输出写进 `build/*-${$}.log`，轮询等到预期输出出现；需要机器状态的脚本再通过 `-monitor unix:...sock` + `socat` 查询寄存器或物理内存，最后断言。`trap cleanup EXIT INT TERM` 负责杀进程、删 socket 和日志。

写新脚本照这个形状抄。断言失败时要打印期望值和实际值两行——学生要把它抄进 `notes/` 的“红灯”一节。

**同步条件与断言条件必须分开**，Makefile 里是两个变量：

- `DEBUGCON_EXPECTED`（当前 `HelloPTLK`）——完整输出，只有 `check-debugcon` 和 `check-kernel-entry` 对它做精确相等断言。
- `BOOT_SYNC_PREFIX`（当前 `HelloPTL`）——a20/gdt/protected/page-tables/long-mode/kernel-load 这六个脚本只用它**前缀匹配**，等到“切换序列已完成”就去查寄存器。

原因：每新增一课都会往 debugcon 输出追加一个字符。如果这六个脚本继续用精确相等，红灯阶段它们会因为 `HelloPTL != HelloPTLK` 集体超时失败，而它们要断言的机制其实全都好着——红灯就不干净了。后续课程追加字符时，只需 bump `DEBUGCON_EXPECTED`，一般不用动 `BOOT_SYNC_PREFIX`。

### docs/ 与 notes/ 成对，结构固定

`docs/lesson-NN.md`：`# 第 N 课：…` → `## 先修知识` → `## 本课只引入一个机制` → 编号小节（含“为什么有这个东西”的历史演化）→ `## 练习` → `## 观察题` → `## 完成标准`。

引入新机制的实验课使用：`## 实验前预测`（或`实验前计算`）→ `## 红灯` → `## 我的实现` → `## 绿灯原始观察` → `## 我的解释` → `## 仍然不清楚的问题`。观察题与“我的解释”按编号一一对应。纯总结章可以改用主题式复盘，不设置红灯/绿灯，也不新增验收命令；第 15、16 课都是这个例外，因此两课都没有 `## 先修知识` 与红/绿灯小节。
- 当前日期默认填充今日

`docs/reference/assembly-basics.md` 是跨课复用的汇编底座，新语法首次出现时补到这里。

### site/：内容从课程仓库单向同步

`site/scripts/sync-content.mjs` 读 `docs/`、`notes/`、`docs/roadmap.md`、`docs/reference/assembly-basics.md`，生成 `site/content/course.generated.ts`（生成物，不要手改）。

**新增一课必须同时在 `sync-content.mjs` 的 `lessonMeta` 数组加一项**（`id`/`slug`/`phase`/`status`/`summary`/`takeaway`），否则新课不会出现在站点上；结课时把 `status` 改成 `completed`。

## 提交约定

一课一提交，工作区必须干净：

- `boot: <做了什么>` — 课程实验（如 `boot: load a minimal global descriptor table`）
- `docs: <做了什么>` — 教材或回顾站
- `course: <做了什么>` — 课程脚手架

提交前跑完全部 `check-*` 和 `cd site && npm run test && npm run lint`。`build/` 已被 gitignore。

## 当前进度

第 0–13 课已结课。CPU 以 `CR4.PAE=1`、`CR3=0x1000`、`EFER.LME=LMA=1`、`CR0.PG=1` 激活 IA-32e mode，并通过 selector `0x18` 的 64 位 code descriptor 在 `0x7d30` 以 `CS64` 执行。硬件首次遍历页表后，三个 entry 的 Accessed 位会被置 1。

第 12 课已用 `INT 13h AH=02h` 把 `build/os.img` 的 CHS `0/0/2`（LBA 1）读到 guest 物理地址 `0x10000`，并验证了完整的 `KERNEL64` 标记。

第 13 课已把 `KERNEL_LOAD_ADDR` 装入 `RAX`，再用 `JMP r/m64` 把执行权交给独立载荷。绿灯证据是 debugcon 输出 `HelloPTLK`、`RIP=0x1000e`、`CS=0x18`（`CS64`）、`RAX=0x1004b`。

第 14 课已结课：ELF64 object、linked `kernel.elf` 与 raw `kernel.bin` 管线已经建立，`.text`、ELF entry 和 `kernel_start` 均为 `0x10000`，运行仍输出 `HelloPTLK`。

第 15 课完成 x86 启动总结后，第 16 课横向对照 x86-64、RV64 RISC-V 与 AArch64；两课都不设置红灯/绿灯。第 17 课再引入第一个 C 函数，System V x86-64 ABI 的必要胶水由脚手架提供，只要求理解调用边界、栈对齐和保存约定。

### 第 15 课：启动总结（纯复盘章）

用户在第 14 课结课后要求"在接 C 之前做一个复盘课"，因此复盘已从"可选、不占课号"升级为正式的第 15 课，排在 C 之前。

起因：前 14 课全部落在"机器怎么工作"这一个轴上，像照着手册实现功能。这个质疑成立且可量化——讲义提到 OSTEP、xv6、6.1810 的次数都是 0，权威引用几乎只有 Intel SDM 与 NASM 文档，14 课的练习动词全是"把这一位设成 1""按这个格式建表""按这个寄存器契约调服务"，没有一道题要求学生**选择**并论证。一部分是 x86 的必然，但 lesson 模板缺"OS 视角""对照实现""设计题""配套阅读"这四个槽位是真的。

本课不引入 guest 机制、不改 boot/kernel 实现代码，也不设置红灯、绿灯或新增验收命令。内容只负责把前 14 课串成一条完整执行路径：reset/BIOS → boot sector → 实模式初始化与读盘 → A20/GDT/保护模式 → 页表/long mode → ELF 载荷，并总结七个设计取舍、六处 C 前缺口、OS 视角映射、xv6/JOS/Linux 对照及配套阅读。

学习记录只写四段总结：完整启动主线、三次控制权移交、交给 C 前已经成立的状态、仍然缺失的内核基础设施。精确寄存器值和设计题不作为完成条件。

本课最重要的发现（讲义 §4.1）：`IDT= base 0 / limit 0x3ff`，即复位后的实模式 IVT，本课程从未执行过 `LIDT`。它至今没炸是因为两个条件同时成立——`RFLAGS.IF=0`（第 9 课的 `CLI` 关的，之后再没 `STI`），且代码从不产生异常。当前 2 MiB 恒等映射包含地址 0，所以空指针解引用不会自动 `#PF`，反而可能静默破坏物理地址 0；未映射访问、除零或非法指令才会暴露无有效 IDT 的 triple-fault 风险。

### 第 16 课：跨 CPU 架构对照（纯讨论章）

横向比较 x86-64、RV64 RISC-V（S-mode/Sv39）与 AArch64 A-profile。主线是 ISA/platform/ABI 三层边界，以及 privilege、page-table root、trap vector、fault state、TLB maintenance、system call、context switch、memory model 和 per-CPU data 的角色映射。

本课不新增代码、命令或验收结果，也不要求背三套寄存器名。学习记录只总结：x86 特有历史路径、三种架构共同 OS 机制、xv6 概念到 x86 的角色翻译、移植时的 portable/arch-specific 边界。第一个 C 函数顺延到第 17 课。

第 16 课专门建立跨架构角色映射；第 17 课起，"OS 视角""对照实现（xv6/Linux/JOS）""设计题""配套阅读"四个槽位常驻。帧分配器阶段开始让学生真正选择并论证数据结构。
