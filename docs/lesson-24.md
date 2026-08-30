# 第 24 课：自制 bootloader 毕业审计

> 本课不引入新机制，不修改 guest 代码，也没有红灯/绿灯。目标是回答一个问题：切换到 Limine 之前，我们是否已经亲手理解并证明了内核真正依赖的启动合同？

## 0. 为什么现在需要停下来审计

第 20–23 课完成了一条连续的职责迁移：

```text
第 20 课：stage 1 能把多扇区 kernel 放入 RAM
第 21 课：stage 1 能加载、执行并返回 stage 2
第 22 课：stage 2 从 BIOS 收集 E820，构造 boot_info
第 23 课：stage 2 按 ELF PT_LOAD 建立 kernel 运行时内存
```

如果现在继续给自制 loader 增加 UEFI、文件系统、磁盘重试、签名验证和高半加载，课程会再次被平台工程吞没。另一方面，如果不做审计就立刻换 Limine，又无法判断我们是否只是把未理解的缺口藏进成熟 bootloader。

因此第 24 课是明确的停止点：

```text
内核主线直接依赖的启动合同    → 必须已经实现、理解并有机器证据
生产 bootloader 的通用能力     → 明确列出，但不继续实现
后续属于内核的资源管理与隔离    → 留给真正的 OS 章节
```

第 25 课才会把这份合同与 Limine 对照。Limine 是替换已理解的实现，不是补洞用的魔法。

## 1. 这一课你到底要做什么

没有新编码任务，也不要求再背地址。你只完成四段短总结：

1. stage 1、stage 2 和 kernel 各自负责什么。
2. kernel 接管 CPU 时，寄存器和内存中有哪些可依赖输入。
3. 选四条机器证据，分别说明“能证明什么”和“不能证明什么”。
4. 把已知限制分成“由成熟 bootloader 替换”和“后续由 kernel 实现”。

最后运行一次聚合命令：

```sh
make check-bootloader-graduation
```

它只复用已经学过的检查，不制造新的测试协议。
输出通过后，把四段总结写入 `notes/05-C内核与Bootloader毕业/note-24.md` 即可。

## 2. 最终控制流：现在到底是谁加载谁

按真实执行顺序：

```text
CPU reset
  → BIOS 初始化平台
  → BIOS 把 LBA 0 的 stage 1 放到 0x7c00
  → stage 1 建立实模式栈
  → stage 1 把 stage2.bin 加载到 0x8000
  → stage 1 CALL stage 2
      → stage 2 写 STAGE2OK
      → stage 2 调 BIOS E820，发布 boot_info
      → stage 2 把 ELF 读到 0x20000 scratch
      → stage 2 对 PT_LOAD 执行 file copy 与 zero-fill
      → stage 2 把 ELF e_entry 写入 boot_info
      → stage 2 RET
  → stage 1 开 A20、加载 GDT、进入保护模式
  → stage 1 建早期页表、进入 long mode
  → stage 1 设置 RDI=boot_info，读取动态 entry 并跳转
  → kernel 切换到自己的栈
  → kernel CALL kernel_main
```

### 三方职责边界

| 组件 | 当前职责 | 不负责什么 |
| --- | --- | --- |
| BIOS | 初始平台环境、加载 stage 1、提供实模式 E820/磁盘服务 | 不知道我们的 `boot_info`、ELF 回执或 C ABI |
| stage 1 | 加载 stage 2；完成 A20、GDT、早期分页和 long-mode 切换；最终 handoff | 不再解析 kernel ELF，也不产生内存图 |
| stage 2 | 保存 boot drive；收集 E820；读取并应用 ELF `PT_LOAD`；发布 entry | 不进入 long mode，不实现 allocator 或通用文件系统 |
| kernel entry | 使用自己的栈，保持 `RDI`，按 SysV ABI 调用 C | 不再调用 BIOS，不重新解析磁盘 ELF |
| C kernel | 校验 handoff，建立 IDT 教学入口，随后拥有全部 OS 策略 | 不能盲信 E820，也不能把所有 type-1 bytes 直接分配 |

这张表就是第 25 课与 Limine 对照时的基准。

## 3. kernel 接管时可依赖的最终合同

### 3.1 CPU 与地址空间

| 状态 | 当前值/性质 | kernel 可以据此做什么 |
| --- | --- | --- |
| 执行模式 | x86-64 long mode、ring 0、`CS=0x18` | 执行 64 位 C/汇编 |
| 分段 | flat base 0 | 把主要隔离职责交给分页 |
| 页表根 | `CR3=0x1000` | 沿当前四级表继续访问低端内存 |
| 映射 | 低 2 MiB 的 2 MiB 恒等映射 | 地址数值与物理地址暂时相同 |
| 中断状态 | `IF=0` | 在完整中断控制器/IDT 就绪前不会接收可屏蔽中断 |

这只是 early mapping，不是最终 kernel address space。一个 2 MiB 大页让代码、数据、栈都共享粗粒度权限，也没有 guard page。

### 3.2 `boot_info` handoff

kernel 的第一个 C 参数是：

```text
RDI = 0x5000 = struct boot_info *
```

32-byte header 当前包含：

| offset | 字段 | 来源 | consumer 如何使用 |
| ---: | --- | --- | --- |
| `0` | magic `BINF` | stage 2 | 先确认结构类型 |
| `4` | version | stage 2 | 判断双方 layout 是否兼容 |
| `6` | E820 entry size `24` | stage 2 | 确认数组步长 |
| `8` | entry count | stage 2 的 E820 loop | 限制遍历上界 |
| `12` | capacity `32` | 自定义合同 | 防止 count 越过 buffer |
| `16` | entries physical `0x5020` | stage 2 | 找到 E820 array |
| `24` | kernel entry physical | ELF `e_entry` | stage 1 的最终 jump target |

这里有两个不同层次：E820 entries 是 firmware 数据；`boot_info` header 是我们自定义的 bootloader→kernel API。

### 3.3 ELF 建立的运行时内存

| 物理区间 | 建立者 | 内容 |
| --- | --- | --- |
| `0x10000..0x107ff` | stage 2 的第一个 `PT_LOAD` | 2048-byte file-backed kernel payload |
| `0x11000..0x15007` | stage 2 的第二个 `PT_LOAD` | zero-filled `.bss`、16 KiB stack 与 probe |
| `RSP=0x15000` | kernel entry | 专用栈顶；返回 hang 后恢复到这里 |

关键规则仍是：

```text
copy p_filesz
zero p_memsz - p_filesz
```

它不仅让代码可执行，也兑现了 C 对未初始化静态对象为零的语言合同。

## 4. 低端内存占用审计

目前所有关键区域都落在低 2 MiB 恒等映射内：

| physical range | owner | 生命周期/说明 |
| --- | --- | --- |
| `0x1000..0x3fff` | early paging | PML4、PDPT、PD |
| `0x5000..0x531f` | boot handoff | header + 最多 32 项 E820 entries |
| `0x7000..0x701f` | 课程证据 | stage 2 / E820 C / ELF C 三组独立 marker |
| `0x7c00..0x7dff` | stage 1 | BIOS boot sector |
| `0x8000..0x83ff` | stage 2 | 1024-byte second stage |
| `0x10000..0x107ff` | kernel file segment | code/data/教学 IDT |
| `0x11000..0x15007` | kernel zero segment | stack + `.bss` probe |
| `0x20000..0x21fff` | stage 2 scratch | 最多 8192-byte loader-facing ELF |
| `0x90000` 向下 | stage 1 temporary stack | kernel 切换自己的栈前使用 |

这些范围当前不重叠，因此 boot 过程可以工作。但内核不能只看到 E820 type 1 就立即分配它们；物理页分配器必须先排除上述 occupied ranges，并按 4 KiB 页对齐。

这正是下一阶段内存管理的输入，而不是 bootloader 继续完成的工作。

## 5. 四组关键机器证据

### 5.1 stage 2 不只是“在磁盘里”

```text
make check-stage2-handoff
```

它同时检查 stage2 image 起点/尾部和 `STAGE2OK`。前者证明 bytes 被完整加载，后者证明 CPU 实际执行过入口。

它不能证明 E820 或 ELF loader 正确；那是后续独立证据。

### 5.2 memory map 真正抵达 C

```text
make check-e820-boot-info
```

它证明 firmware entries 非空、stage 2 发布动态 count、`RDI` handoff 抵达 C，最终由 C 写出 `E820COK!`。

它不能证明 type-1 ranges 已经排除 kernel/loader 占用，也不能证明 allocator 已建立。

### 5.3 kernel 真正来自 ELF，而不是历史 raw bytes

```text
make check-elf-loader
```

它破坏临时镜像中的 raw LBA 1..4；系统仍能运行，说明 stage 2 使用了 LBA 18 的 ELF。它还检查 dynamic entry、zero-filled probe、专用栈和 `ELF64OK!`。

它不能证明 loader 支持任意 ELF、高半地址、重定位或严格的页权限。

### 5.4 kernel 的最小异常链仍成立

```text
make check-exception
```

它证明 ELF/stack 改造后，`UD2 → vector 6 → C → IRETQ` 仍能恢复到历史 hang。

它不能证明完整 IDT；当前只有 vector 6 有效，`#PF` 等异常仍没有可靠入口。

### marker 不能互相冒充

| marker | writer | 能证明 |
| --- | --- | --- |
| `STAGE2OK` at `0x7000` | 16-bit stage 2 | stage 2 入口真实执行 |
| `E820COK!` at `0x7010` | 64-bit C | boot-info memory map 被 C 消费 |
| `ELF64OK!` at `0x7018` | 64-bit C | zero-fill 与专用栈被 C 观察到 |

它们都是课程测试协议，不是 BIOS、ELF 或 SysV ABI 的标准字段。

## 6. “毕业”明确不包含什么

### 6.1 将由成熟 bootloader 替换的教学限制

| 限制 | 当前实现 | 为什么不继续投入 |
| --- | --- | --- |
| 平台 | 只支持 legacy BIOS/软盘镜像 | 第 25 课用成熟 loader 隔离 BIOS/UEFI 差异 |
| 磁盘定位 | 写死 CHS/LBA 和读取长度 | 真正 loader 应理解启动介质或文件系统 |
| 错误恢复 | 失败后输出 `E` 并死循环 | 生产实现需要重试、诊断和更多设备路径 |
| ELF window | scratch 固定 8192 bytes、单个 real-mode window | 足以证明算法，不是通用 ELF loader |
| ELF 地址 | 只接受低端、16-byte-aligned `p_paddr` | 高半加载与重定位不应继续塞进教学 stage 2 |
| 安全启动 | 无签名、哈希、Secure Boot | 不属于本课程 OS 主线 |

### 6.2 必须由 kernel 后续实现的 OS 能力

| 尚缺能力 | 为什么属于 kernel |
| --- | --- |
| 物理页分配器 | kernel 决定哪些 E820 pages 可分配、如何维护状态 |
| 正式页表 | kernel 决定虚拟地址布局、权限、NX、guard pages |
| 完整 IDT | kernel 定义异常策略、page fault、设备中断入口 |
| PIC/APIC 与定时器 | kernel 才能建立抢占、调度和设备中断 |
| 用户态与系统调用 | 属于隔离和进程模型，不是加载 kernel 的职责 |
| 正式串口/console | debugcon 只是 QEMU 教学通道 |
| SMP | 当前只启动 bootstrap processor |

把两张表分开很重要：成熟 bootloader 可以替换第一张表中的平台实现，但不会替 kernel 完成第二张表中的 OS 策略。

## 7. 为什么现在足以进入 Limine 对照

切换前，我们已经亲手回答了这些问题：

- CPU 怎样从 reset 抵达 64 位 kernel entry？
- BIOS 环境为什么必须在切换模式前收集资源？
- memory map 是怎样跨过汇编/C 边界的？
- loader 为什么按 `PT_LOAD` 而不是 section name 建立内存？
- `.bss` 为什么不占 file bytes，却必须在 RAM 中为零？
- kernel 调用 C 前需要怎样的栈与参数状态？
- 如何区分“文件存在”“bytes 被加载”“CPU 执行”“C 已消费”四类证据？

因此，第 25 课看到成熟协议返回 memory map、kernel address、framebuffer 或其他信息时，我们能够判断每个字段替代了自己哪一段实现，也能判断哪些事情仍必须由 kernel 完成。

## 8. 聚合验收

阅读完上述合同后运行：

```sh
make check-bootloader-graduation
```

它按顺序复用：

```text
check-boot
check-stage2-handoff
check-e820-boot-info
check-elf-loader
check-long-mode
check-exception
```

这不是新的绿灯机制，只是把已有证据收在一个命令下。不要把整段输出重复抄进笔记，只记录最后的 graduation summary。

## 9. 学习记录

在 `notes/05-C内核与Bootloader毕业/note-24.md` 写四段即可：

1. stage 1 → stage 2 → kernel 的职责边界。
2. 最终 handoff：CPU 状态、`RDI`、ELF entry、`.bss` 和 stack。
3. 四条证据各自能证明/不能证明什么。
4. 至少各举三项：成熟 bootloader 替换的限制、kernel 后续实现的能力。

不要求背所有地址；能沿着 producer → handoff → consumer 说清因果即可。

## 完成标准

- 不修改 `boot/` 或 `kernel/` 代码。
- `make check-bootloader-graduation` 通过。
- 能准确区分 stage 1、stage 2、firmware 与 kernel 的职责。
- 能解释三组 marker 为什么不能互相替代。
- 能把“自制 loader 不做”和“kernel 尚未做”分开。
- 能说明为什么第 25 课切换 Limine 不会掩盖启动知识缺口。
