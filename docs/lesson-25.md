# 第 25 课：认识 Limine，把启动合同交给成熟 bootloader

> 本课是正式换轨章。先认识 Limine，再把它与第 0–24 课逐项对照，最后启动一个新的高半 C 内核并消费第一份 Limine memory-map response。我们替换的是已理解的启动实现，不是删除启动知识。

## 0. 这不是又一轮 bootloader 课程

第 24 课已经证明，我们自己的路径能够完成：

```text
BIOS → stage 1 → stage 2 → E820 → boot_info
     → ELF PT_LOAD → long mode → stack → C
```

继续完善它，下一批工作会是 UEFI、文件系统、更多磁盘驱动、错误恢复、通用 ELF relocation 和安全启动。这些工作很有价值，但会继续占用本课程本应投入 allocator、页表、用户态、调度和文件系统的时间。

本课将新的边界固定为：

```text
firmware → Limine → kernel entry       由成熟实现承担
kernel entry → allocator → processes   从现在起是课程主线
```

旧路径不会被删除。它留在仓库里继续通过全部历史 `check-*`，既是我们已经掌握的证据，也是以后诊断 Limine handoff 的对照组。

## 1. 先分清三个容易混在一起的名字

### 1.1 Limine bootloader

Limine 是一个现代、可移植、多协议的 bootloader/boot manager。它支持 x86-64、AArch64、RISC-V 等架构，也能从 BIOS 或 UEFI 环境启动。

本课程固定使用：

```text
Limine bootloader 12.5.2
x86-64 UEFI path
```

固定版本是为了让实验可重复，不表示课程要求记住版本号。

### 1.2 Limine boot protocol

Limine boot protocol 是 **bootloader 与 kernel 之间的数据合同**。Limine bootloader 是这个协议的参考实现，但二者不是同一个概念：

```text
bootloader = 执行加载工作的程序
protocol   = loader 与 kernel 共同遵守的接口
```

类比我们原来的实现：

```text
stage 1 + stage 2           ≈ bootloader 实现
boot_info.h + RDI 约定      ≈ 自定义 boot protocol
```

### 1.3 `limine.h`

`limine.h` 是官方协议结构的 C/C++ 定义。它不是一个要链接的运行库，也不会在 kernel 中偷偷执行加载代码；它只给出 request、response、常量和布局。

课程把 header 固定到官方 `limine-protocol` commit `4e1587972c14`，并校验 SHA-256。第一次构建时会下载固定的 bootloader binary 和 header 到 `build/limine/`；这些是可重建依赖，不进入课程源码提交。

### 1.4 本章新名词地图

先不要把所有英文当成同一层。下面按“平台 → 文件 → 协议 → 地址空间 → 内核所有权”分类；后文再次出现时，都使用这里的含义。

#### 平台与启动程序

| 名词 | 直白解释 | 在本课中是谁 |
| --- | --- | --- |
| firmware（固件） | CPU 复位后先运行的平台软件，先于我们的 kernel | QEMU 提供的 x86-64 UEFI firmware |
| BIOS | 老式 PC firmware 接口；我们曾通过中断调用其磁盘/E820 服务 | 旧自制 bootloader 路径使用 |
| UEFI | 现代 firmware 规范，能加载 EFI application，并提供启动期服务 | 新 Limine 路径使用 |
| EFI application | UEFI 能识别和执行的程序文件 | `BOOTX64.EFI`，也就是 Limine 的 x86-64 UEFI 入口 |
| Boot Services | UEFI 在启动期提供的内存、文件、设备等服务 | Limine handoff 前退出；kernel 不能继续把它当普通函数库调用 |
| bootloader | 找到、加载并把控制权交给 kernel 的程序 | Limine |
| boot manager | 选择启动哪个系统/菜单项的程序 | Limine 同时具备这个角色 |
| Secure Boot | firmware 对启动程序签名建立信任链的机制 | 本课程实验不启用，也不由 kernel allocator 负责 |

`BOOTX64.EFI` 里的 `X64` 表示 x86-64，`EFI` 表示 UEFI 可执行格式。它不是我们的 kernel；它先运行，再加载 `kernel.elf`。

#### 文件与链接

| 名词 | 直白解释 | 本课对应物 |
| --- | --- | --- |
| executable | 可被 loader 加载并进入的程序文件 | `limine-kernel.elf` |
| ELF entry | ELF header 声明的第一条 kernel 指令地址 | `0xffffffff80001000` |
| VMA | CPU 运行时使用的虚拟地址 | linker script 中从 `0xffffffff80000000` 开始的地址 |
| PHDR / program header | 告诉 loader“哪些 file bytes 要成为哪些内存段”的表项 | request、text、rodata、data 四个 `PT_LOAD` |
| `PT_LOAD` | program header 中真正要求 loader 建立的可加载段 | Limine 按它复制、清零并设置映射权限 |
| `PF_X` / `PF_W` | ELF segment 的 executable / writable 权限标志 | Limine 用它们决定初始页表权限 |
| relocation / slide | 改变装载基址时修正或整体平移程序地址 | 成熟 loader 的职责之一；本课使用固定高半 VMA |
| linker garbage collection | 删除最终程序没有引用的 section | `KEEP` 防止 protocol requests 被误删 |
| `-mcmodel=kernel` | 编译器生成适合 x86-64 顶部 2 GiB 内核地址的寻址代码 | 新 kernel 的编译选项，不是 CPU mode |
| FAT image | 带 FAT 文件系统的磁盘镜像 | UEFI 从中找到 `EFI/BOOT/BOOTX64.EFI`，Limine 再找到 kernel |

PHDR 是 **program header** 的常见缩写，不是“物理地址 header”。section 主要服务 linker/debugger；program header 主要服务 loader。第 23 课已经验证过 loader 应消费 `PT_LOAD`，这里由 Limine 接手同一职责。

#### 协议与数据流

| 名词 | 直白解释 |
| --- | --- |
| boot protocol | bootloader 与 kernel 约定的数据布局和入口状态 |
| handoff | bootloader 最后一次把机器状态、数据所有权和控制权交给 kernel |
| feature | protocol 中一项可单独请求的能力，例如 memory map、HHDM、framebuffer |
| request | kernel 嵌入 ELF 的“我需要这项 feature”数据对象 |
| response | bootloader 在运行时填回的结果对象 |
| request marker/delimiter | 标出 requests 扫描范围的特殊 magic values，不是要执行的指令 |
| base revision | 整个 Limine protocol 的总体行为版本 |
| request revision | 某一项 feature request 自己的结构版本；与 base revision 不是同一个数字 |
| reference implementation | 某协议的官方/主要实现；协议仍是合同，实现则是程序 |
| magic value | 双方约定的特殊常量，用来识别结构或 marker；它本身不是指令 |
| SHA-256 | 对下载内容计算的固定长度摘要，用来发现版本错误或文件损坏 |

后文顺带出现但本课不实现的 Limine features：

| 名词 | 它提供什么 |
| --- | --- |
| framebuffer | 一块可按像素写入的显示内存及其尺寸、pitch、颜色布局 |
| RSDP | ACPI 根指针，kernel 从它开始寻找 CPU、APIC 等平台描述表 |
| SMP | symmetric multiprocessing，多 CPU/core 的启动与协作 |
| module | bootloader 随 kernel 一起加载的额外文件，例如 initramfs |

#### 地址空间与内存所有权

| 名词 | 直白解释 |
| --- | --- |
| virtual address（VA） | CPU 指令使用、再由页表翻译的地址 |
| physical address（PA） | RAM/设备在物理地址空间中的位置编号 |
| identity map | `VA == PA` 的映射；旧 kernel 的低 2 MiB 就是这样 |
| higher half（高半） | x86-64 canonical virtual address space 上方的区域，不是超大物理内存 |
| higher-half kernel | 代码链接并运行在高半虚拟地址的 kernel |
| HHDM / direct map | 把一批物理内存按统一 offset 映射到高半的窗口 |
| page tables | CPU 用来完成 VA → PA 翻译并检查权限的数据结构 |
| memory map | 描述哪些物理地址范围可用、保留或暂可回收的资源清单 |
| normalized memory map | Limine 把 BIOS/UEFI 等平台差异整理成统一的 protocol entry 类型 |
| allocator | 记录并改变“哪些页空闲、哪些页已分配”的 kernel 所有权状态机 |
| bootloader-reclaimable | bootloader 不再执行后最终可以回收，但 kernel 当前可能仍在使用的内存 |
| kernel-owned | 生命周期和释放条件已经由 kernel 自己管理的内存/页表/栈 |

最后三项不能混为一谈：memory map 是“资源说明书”，allocator 是“领用登记系统”，kernel-owned 是“已经完成所有权接管”的状态。

## 2. request/response：新的 handoff 到底怎样发生

我们的 `boot_info` 路径是：

```text
stage 2 主动构造一个总表
stage 1 把总表地址放进 RDI
kernel_main(struct boot_info *info) 接收它
```

Limine protocol 的方向不同：kernel 先在 ELF 中声明“我需要什么”。例如 memory map request：

```c
__attribute__((used, section(".limine_requests")))
static volatile struct limine_memmap_request memory_map_request = {
    .id = LIMINE_MEMMAP_REQUEST_ID,
    .revision = 0,
};
```

运行时的真实顺序是：

```text
1. linker 把 request 保留在 kernel ELF
2. Limine 加载 ELF，并扫描 start/end marker 之间的 requests
3. Limine 识别 memory-map request
4. Limine 把 response 指针写入 memory_map_request.response
5. Limine 跳到 ELF entry
6. kernel 读取 response，而不是调用 Limine 函数
```

因此它不是普通函数调用，也不是进入 kernel 后仍可使用的 UEFI service。x86-64 UEFI 路径会在 handoff 前退出 boot services。

### producer、consumer 与 observer

| 角色 | 本课是谁 | 实际动作 |
| --- | --- | --- |
| request producer | kernel ELF | 声明需要 memory map |
| response producer | Limine | 填入 response 和 entries |
| response consumer | `limine_kernel_main` | 校验并遍历返回结果 |
| observer | `check-limine-handoff` | 观察 ELF 与 port `0xe9` 证据 |

`check-limine-handoff` 是课程测试协议，不属于 Limine 标准。`LIMINE:ENTRY` 和 `LIMINE:MEMMAP:OK` 也只是我们的可观察 marker。

## 3. Limine 交给 x86-64 kernel 的入口环境

### 3.1 “高半地址”到底是什么

全文统一称为 **高半地址**（higher-half address）。“半高地址”只是容易发生的口误。

先看我们当前使用的四级分页模型。x86-64 指令里虽然能写 64-bit 地址，但四级分页通常只使用低 48 位，并要求高位是 bit 47 的符号扩展。这种满足规则、CPU 接受的地址叫 **canonical address**：

```text
0x0000000000000000 ─┐
                    │ lower canonical half（低半）
0x00007fffffffffff ─┘

0x0000800000000000 ─┐
                    │ non-canonical hole
0xffff7fffffffffff ─┘  这些数值不能当普通虚拟地址使用

0xffff800000000000 ─┐
                    │ upper canonical half（高半）
0xffffffffffffffff ─┘
```

因此“高半”是 **canonical virtual address space 的上半区域**。它不是说机器有接近 `2^64` bytes 的 RAM，也不是把代码加载到了天文数字大小的物理内存。

本课把 kernel 的链接基址选为：

```text
kernel base  = 0xffffffff80000000
text entry   = 0xffffffff80001000
```

`0xffffffff80000000` 位于高半靠近顶端的 2 GiB 区域。`text entry` 比它大 `0x1000`，是因为 linker 先放一页 protocol requests，再把 `.text` 对齐到下一页。

### 3.2 高虚拟地址如何落到真实 RAM

把地址画成两侧最直观：

```text
ELF / CPU 看到的虚拟地址                 实际物理内存

0xffffffff80001000  ── page tables ──→  某个 Limine 选择的物理页
        RIP                                      RAM bytes
```

Limine 做两件不同的事：

1. 找物理页存放 ELF 的 `PT_LOAD` 内容并清零 `.bss`。
2. 建页表，让高半 VMA 能翻译到这些物理页，并按 `PF_X/PF_W` 设置权限。

所以当前成立的是：

```text
virtual 0xffffffff80001000 ≠ physical 0xffffffff80001000
```

具体物理落点不需要由 kernel 猜；需要时应通过 executable-address 等协议数据或自己的页表状态获得。物理内存只有 256 MiB，也完全可以映射一个数值接近 `2^64` 的虚拟地址。

对比旧路径：

```text
旧 kernel：VA 0x10000 ──identity map──→ PA 0x10000
新 kernel：VA 0xffffffff80001000 ──Limine page tables──→ 某个 PA
```

### 3.3 为什么 kernel 喜欢放在高半

这是一种地址空间布局策略，不是硬件强制要求。常见收益是：

- 低半长期留给每个用户进程，kernel 固定在高半。
- 切换进程页表时，可以让不同进程拥有不同低半，同时共享同一套 kernel 高半映射。
- kernel code/data 与用户地址在数值上明显分区，权限设计和调试更清晰。
- HHDM 可以在另一段高半区域提供统一的“物理内存窗口”。

高半本身不自动带来安全：真正的隔离仍来自 page-table 的 user/supervisor、writable、executable 等权限位，以及 kernel 对用户指针的检查。

### 3.4 高半 kernel mapping 不等于 HHDM

这两者都在高半，所以经常被误认为同一个东西：

```text
kernel mapping：把 kernel ELF 的 code/data 映射到其 VMA
HHDM mapping：  把物理内存 p 映射到 hhdm_offset + p
```

例如 kernel entry 可以位于 `0xffffffff80001000`，而 HHDM offset 是另一个由 bootloader 选择并通过 request 返回的地址。不能拿 kernel base 当 HHDM offset，也不能看到一个高半指针就盲目减去 `0xffffffff80000000`。

### 3.5 入口机器合同

本课使用当前官方推荐的 base revision 6。base revision 是整个协议的行为版本，不是某个单独 request 的 revision。

进入 kernel 时，与当前课程直接有关的合同是：

| 状态 | Limine 保证 | 对 kernel 的含义 |
| --- | --- | --- |
| 执行模式 | ring 0、64-bit mode，分页已启用 | 不再手写 A20/GDT/mode switch |
| `RIP` | ELF entry 的高半虚拟地址 | linker script 决定入口 VMA；页表决定它落到哪个 PA |
| 栈 | 至少 64 KiB，位于 bootloader-reclaimable memory | C 可立即运行，但以后要换成 kernel-owned stack |
| 通用寄存器 | `RAX`–`R15` 为 0 | **没有**旧课程的 `RDI=boot_info` |
| flags | `IF=0`、`DF=0`、`VM=0` | 可屏蔽中断尚未打开；字符串方向确定 |
| paging | bootloader page tables 已生效 | 可运行高半 kernel，但不是最终 kernel 页表 |
| IDT | 未定义 | kernel 必须尽早加载自己的 IDT |
| ABI | SysV x86-64，不使用 FP/SIMD 传递协议数据 | 我们已经学过的 C ABI 仍然有效 |

这第一次把“高半内核”从讲义概念变成真实执行地址。

## 4. 两类地址不要再混用

在 Limine response 中要同时面对：

- `response`、`entries`、每个 entry 指针：kernel 可以解引用的 **高半虚拟指针**。
- `entry->base`：该 memory-map range 的 **物理地址数值**。

Limine 还可通过 HHDM request 返回 Higher Half Direct Map（高半直接映射）offset。它是一段“物理地址整体加同一偏移量”的虚拟窗口。将来若要访问物理页 `p`，通常使用：

```text
virtual = hhdm_offset + p
```

但本课只读取 Limine 已经返回的 response 指针，不实现页帧分配，也不假设固定 HHDM offset。

另一个所有权条件很重要：response、bootloader page tables 和初始栈都可能位于 `BOOTLOADER_RECLAIMABLE` memory。这个类型表示“bootloader 已经不会再用，允许 kernel 在满足条件后接管”，并不表示“现在一定空闲”。只要 kernel 仍在使用 response、初始页表或初始栈，就不能把对应页交给 allocator。名字叫“可回收”不等于“入口第一行就能回收”。

## 5. 把第 0–24 课逐项映射过来

### 5.1 谁接手了我们的实现

| 我们亲手做过的事 | Limine 路径中的替代者 | kernel 现在看到的结果 |
| --- | --- | --- |
| BIOS 把 boot sector 放到 `0x7c00` | UEFI 加载 `BOOTX64.EFI` | kernel 不再依赖 `0x7c00` |
| stage 1/stage 2 读固定 LBA | Limine 的介质与文件系统路径 | `limine.conf` 用文件路径指定 ELF |
| A20、GDT、`CR0.PE`、PAE、LME、PG | firmware + Limine 的架构入口 | kernel 直接在 64-bit paging 环境执行 |
| 自建低 2 MiB identity map | Limine 建立 kernel/HHDM mappings | kernel 入口是高半地址 |
| BIOS E820 loop | Limine memory-map feature | kernel 消费规范化的 memmap response |
| `boot_info` header + `RDI` | 独立 request/response objects | kernel 主动声明所需 features |
| stage 2 解析 `PT_LOAD`、清零 `.bss` | Limine ELF loader | executable segments 按权限映射，`.bss` 合同成立 |
| 自己设置 `RSP=0x15000` | Limine 初始栈 | entry 立即满足最小 C 环境 |

### 5.2 哪些知识没有被替换

- ELF entry、`PT_LOAD`、`p_filesz/p_memsz` 仍解释代码为何在正确地址运行。
- SysV ABI、栈方向和对齐仍解释 C 函数为什么能正确调用。
- 分页仍解释高半 kernel、HHDM、权限和最终地址空间。
- producer → handoff → consumer → observer 的证据方法完全不变。
- 异常帧、IDT、allocator、中断、用户态和调度仍由 kernel 实现。

Limine 替换了启动机制的实现成本，但没有替换这些机制的因果关系。

## 6. 哪些事情 Limine 明确不会替我们完成

启动成功后仍然缺少：

```text
可信的完整 IDT
物理页状态与 allocator
kernel-owned page tables
guarded kernel stacks
APIC / timer / device interrupts
用户地址空间与系统调用
进程、调度、同步、VFS 与文件系统
```

尤其不要把“Limine 给了 memory map”误解为“已经有内存管理”：memory map 只是资源描述，allocator 才是所有权状态机。

## 7. 本课新增的独立启动路径

旧路径和新路径并存：

```text
旧：boot/ + kernel/payload.asm + build/os.img
    make check-bootloader-graduation

新：kernel/limine_main.c + kernel/limine_linker.ld
    + limine.conf + build/limine-os.img
    make check-limine-handoff
```

新镜像使用 QEMU 的 x86-64 UEFI 固件启动。依赖固定版本并经过 hash 校验；这部分由脚手架负责，不作为记忆或抄写题。

先静态观察新 ELF：

```sh
make inspect-limine-handoff
```

关注三项：

1. entry 位于 `0xffffffff80001000`。
2. `.limine_requests` 没有被 linker garbage collection 删除。
3. ELF 中同时存在 base revision、memory-map request 和 entry symbol。

## 8. 当前红灯为什么必然失败

`kernel/limine_main.c` 已经包含有效 request 和可运行 entry，但：

```c
static bool accept_limine_handoff(void) {
    /* RED / TODO ... */
    return false;
}
```

因此当前程序会写出：

```text
LIMINE:ENTRY
```

它证明 UEFI → Limine → ELF entry 已成立。由于 consumer 主动拒绝 response，不会写出 `LIMINE:MEMMAP:OK`，checker 才会红。

这次红灯不表示 Limine 没加载 kernel，也不表示 request 缺失；失败层被刻意限制在“kernel 尚未接受 handoff”。

## 9. 实验前预测

第一次运行 `make check-limine-handoff` 前，根据第 2、3、7、8 节填写 `notes/note-25.md`。所有问题都能直接从当前源码和正文推出。

### 9.1 当前红灯

1. debugcon 一定出现哪一行？
2. 哪一行一定不会出现，直接原因是什么？
3. 红灯能否证明 Limine 已经跳入高半 kernel？依据是什么？
4. 它能否证明 kernel 已正确消费 memory map？为什么？

### 9.2 request/response

1. request 的 producer 是谁？
2. response 的 producer 是谁？
3. response 的 consumer 是谁？
4. 为什么 entry 不再从 `RDI` 读取 `boot_info`？

### 9.3 与旧路径对照

分别写出下列旧机制在新路径中的对应物：

- stage 2 E820 loop
- `boot_info` + `RDI`
- stage 2 ELF loader
- stage 1 long-mode switch

## 10. 运行红灯

填完预测后运行：

```sh
make check-limine-handoff
```

预期核心输出：

```text
Limine handoff check: the higher-half kernel entry ran,
but the memory-map response was not accepted
Limine handoff output: LIMINE:ENTRY
```

把真实输出保留到学习记录中，再开始修改。

## 11. 你的实现任务

只修改：

```text
kernel/limine_main.c
```

### 11.1 先修复编辑器提示

`limine.h` 不是 macOS 系统头文件，也不在源码目录。它由课程下载到：

```text
build/limine/include/limine.h
```

如果 VS Code 显示：

```text
cannot open source file "limine.h"
Please update your includePath
```

这是 **IntelliSense 的 include path 错误**，不是 kernel 编译错误。仓库现在提供了 `.vscode/c_cpp_properties.json`，其中包含交叉编译器和该目录。先运行：

```sh
make limine-deps
```

它会取得经过 hash 校验的固定版本 header。一般重新打开 `kernel/limine_main.c` 后红线就会消失；若 VS Code 保留旧缓存，执行命令面板中的 `C/C++: Reset IntelliSense Database`。

命令行构建始终以 Makefile 的：

```text
-I build/limine/include
```

为准。编辑器没有红线只证明它找得到声明，不证明 kernel 已经编译或运行。

### 11.2 不要猜 API：直接观察官方定义

运行：

```sh
make inspect-limine-api
```

它从本地固定版本的官方 `limine.h` 摘出本实验所需定义。先把结果读成下面这条指针链：

```text
memory_map_request
  .response                    struct limine_memmap_response *
    ->entry_count              返回多少个 range
    ->entries[index]           struct limine_memmap_entry *
        ->base                 range 的物理起点
        ->length               range 的 byte 数
        ->type                 range 的用途类型
```

这里 `.` 和 `->` 的区别是：

```c
object.field       // 手里是结构体对象
pointer->field     // 手里是指向结构体的指针
```

所以入口对象用：

```c
memory_map_request.response
```

取得 response 指针之后则用：

```c
response->entry_count
response->entries[index]
```

`entries` 不是连续的 entry 结构数组，而是 **entry 指针数组**，因此还要取得：

```c
const struct limine_memmap_entry *entry = response->entries[index];
```

再读取 `entry->type` 与 `entry->length`。

### 11.3 四层检查分别在防什么

完成 `accept_limine_handoff()`，按顺序建立四层防线：

1. `LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)` 必须为真：防止 kernel 按 bootloader 不支持的总体协议行为解释数据。
2. `memory_map_request.response` 不能为 `NULL`：防止 feature 未得到 response 时解引用空指针。
3. `response->entry_count` 必须大于 0：防止把一张空资源表当成可用内存来源。
4. 遍历 `response->entries`，至少找到一项 `type == LIMINE_MEMMAP_USABLE` 且 `length >= 4096`：不仅检查“有数据”，还检查数据中至少存在一页真正可用的物理内存。

只有四项都成立时返回 `true`。不要写死 QEMU 的 entry count、物理地址或 HHDM offset。

### 11.4 逐级提示

先只看提示 1；仍卡住再向下看。

<details>
<summary>提示 1：函数骨架</summary>

失败条件直接 `return false`；遍历找到符合条件的 entry 时立即 `return true`；循环结束仍未找到则 `return false`。

</details>

<details>
<summary>提示 2：response 的局部变量类型</summary>

```c
const struct limine_memmap_response *response = memory_map_request.response;
```

`const` 表示 consumer 只读取 Limine 的 response，不在本实验中修改它。

</details>

<details>
<summary>提示 3：遍历形状</summary>

```c
for (uint64_t index = 0; index < response->entry_count; ++index) {
    const struct limine_memmap_entry *entry = response->entries[index];
    /* 先检查 entry，再检查 type 和 length。 */
}
```

</details>

提示没有给出最终函数全文：版本检查、两个 early return 和 entry 条件仍由你组合。源码 TODO 上方也保留了同一提示阶梯，避免在编辑器与讲义之间反复切换。

实现后再次运行：

```sh
make check-limine-handoff
```

绿灯应证明：

```text
UEFI
  → Limine
  → higher-half ELF entry
  → request/response
  → kernel consumer
```

它仍然不能证明 allocator 已经存在，也不能证明 memory-map 中的所有 range 都可直接分配。

## 12. 为什么只让你实现 consumer

下载 bootloader、制作 FAT 镜像、放置 EFI executable、编写 linker PHDR 和设置 `-mcmodel=kernel` 都是真实工程步骤，但它们不是本课要训练的 OS 判断。

你真正需要掌握的是：

```text
kernel 声明需求
bootloader 生产 response
kernel 校验版本、存在性、边界和语义
测试分别证明 entry 与 consumption
```

以后加入 HHDM、framebuffer、RSDP、SMP 或 modules 时，仍然复用同一种思考方式。

## 13. 新旅程从哪里开始

完成本课后，bootloader 主线正式结束。接下来的章节默认基于 Limine kernel：

```text
第 26 课  从 memory map 建立物理页 ownership
第 27+课 建立 kernel-owned page tables 与 HHDM 使用边界
随后      完整异常、APIC/timer、用户态与系统调用
再随后    进程/线程、调度、同步、VFS 与文件系统
```

第一站是物理页分配器，因为现在已经有了可信的资源描述，却还没有任何资源所有权状态。这正是从“CPU 能运行内核”走向“内核开始管理机器”的分界线。

## 14. 官方参考

- [Limine：bootloader/reference implementation](https://github.com/Limine-Bootloader/Limine)
- [Limine Boot Protocol specification](https://github.com/Limine-Bootloader/limine-protocol/blob/trunk/PROTOCOL.md)
- [官方 `limine.h`](https://github.com/Limine-Bootloader/limine-protocol/blob/trunk/include/limine.h)
- [官方 C template](https://github.com/Limine-Bootloader/limine-c-template)
- [Limine configuration reference](https://github.com/Limine-Bootloader/Limine/blob/v12.x/CONFIG.md)

## 完成标准

- 能区分 Limine bootloader、Limine boot protocol 与 `limine.h`。
- 能解释 request/response 不是运行时函数调用。
- 能把旧 bootloader 的关键职责逐项映射到 Limine。
- 能说明 `RDI=boot_info` 为什么不再是入口合同。
- `make check-limine-handoff` 绿灯，且实现不写死机器特定 entry count/address。
- 旧的 `make check-bootloader-graduation` 仍通过。
- 能说出至少四项仍必须由 kernel 完成的 OS 机制。
