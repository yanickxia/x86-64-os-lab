# 第 25 课学习记录

日期：2026.08.12

> 先读讲义第 0–9 节，再填写预测。第一次运行 `make check-limine-handoff` 前完成；错误预测不要覆盖，实验后在“我的解释”中修正。

## 实验前预测

### 1. 当前红灯

- debugcon 一定出现：LIMINE:ENTRY
- debugcon 一定不会出现：LIMINE:MEMMAP:OK
- 直接原因：由于 consumer 主动拒绝 response，不会写出 LIMINE:MEMMAP:OK，checker 才会红
- 红灯能否证明 Limine 已跳入高半 kernel，依据：没有。因为还没有执行内核
- 红灯能否证明 kernel 已消费 memory map，原因：能，因为没有打印 LIMINE:MEMMAP:OK

### 2. request/response 四个角色

- request producer：kernel ELF
- response producer：Limine
- response consumer：limine_kernel_main
- observer：check-limine-handoff
- 为什么不再通过 `RDI` 接收总 `boot_info`：独立 request/response objects

### 3. 与旧路径对照

| 旧机制                   | 新路径中的对应物              |
| ------------------------ | ----------------------------- |
| stage 2 E820 loop        | Limine memory-map feature     |
| `boot_info` + `RDI`      | 独立 request/response objects |
| stage 2 ELF loader       | Limine ELF loader             |
| stage 1 long-mode switch | Limine                        |

## 静态观察

### `make inspect-limine-handoff`

只摘录并解释三项：

- ELF entry：
  ```
  LOAD           0x001000 0xffffffff80000000 0xffffffff80000000 0x000080 0x000080 RW  0x1000
  LOAD           0x002000 0xffffffff80001000 0xffffffff80001000 0x000034 0x000034 R E 0x1000
  LOAD           0x003000 0xffffffff80002000 0xffffffff80002000 0x00000e 0x00000e R   0x1000
  LOAD           0x000120 0x0000000000000000 0x0000000000000000 0x000000 0x000000 RW  0x1000
  ```
- `.limine_requests` 的地址/ffffffff80000000 WA
- 三个协议对象与 kernel entry symbol：memory_map_request ffffffff80000020
- 为什么 entry 数值很大，却不要求同样大小的物理内存：没看懂，不知道


## 红灯

### `make check-limine-handoff`

```text
Limine/UEFI host tools check passed
Limine handoff check: the higher-half kernel entry ran, but the memory-map response was not accepted
Limine handoff check: complete accept_limine_handoff() in kernel/limine_main.c
Limine handoff output: LIMINE:ENTRY
make: *** [check-limine-handoff] Error 1
```

为什么 `LIMINE:ENTRY` 已经成立，checker 仍应失败：因为 consumer 主动拒绝 response，不会写出 LIMINE:MEMMAP:OK，checker 才会红


## 我的实现

`accept_limine_handoff()` 的四层检查：

```
if (!LIMINE_BASE_REVISION_SUPPORTED(limine_base_revision)) {
    return false;
}

struct limine_memmap_response *response = memory_map_request.response;
if (response == NULL || response->entry_count == 0) {
    return false;
}

bool found_usable = false;

for (size_t i = 0; i < response->entry_count; i++) {
    struct limine_memmap_entry *entry = response->entries[i];

    if (entry->type == LIMINE_MEMMAP_USABLE && entry->length >= 4096) {
        found_usable = true;
        break;
    }
}

return found_usable;
```

为什么不能写死 `entry_count` 或某个物理地址：因为 `entry_count` 是 Limine 生成的，而物理地址是 kernel 生成的。


## 绿灯

### `make check-limine-handoff`

```text
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK'
```

### 旧路径回归

`make check-bootloader-graduation`：

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
stage2 check passed: stage 1 loaded and called stage 2, which returned to the historical boot path
stage2 state: image 0x8000..0x83ff, handshake 0x4b4f324547415453 at 0x7000, output='HelloPTLKCUR'
E820 check passed: stage 2 published 7/32 entries and C consumed boot_info
E820 state: header=0x00180001464e4942, entries=0x5020, first_length=0x000000000009fc00, C_ack=0x214b4f4330323845, output='HelloPTLKCUR'
ELF loader check passed: corrupted raw LBA 1 was ignored; stage 2 loaded 2048 file bytes from PT_LOAD
ELF state: entry=0x0000000000010000, bss_probe=0x0000000000000000, stack=0x0000000000011000..0x0000000000015000, RSP=0x0000000000015000, C_ack=0x214b4f3436464c45
long-mode check passed: CPU is executing 64-bit code
long-mode state: CR0=80000011 CR2=0000000000000000 CR3=0000000000001000 CR4=00000020
long-mode state: CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
long-mode state: EFER=0000000000000500
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x00000000000101e0 limit=0x006f, output='HelloPTLKCUR'
bootloader graduation audit passed:
  stage 1 → stage 2 execution boundary
  E820 → boot_info → RDI → C
  ELF PT_LOAD → .bss zero-fill → dedicated stack
  long mode + minimal #UD recovery remain intact
```

## 我的解释

### 1. request/response 不是函数调用
类似于回调函数，是一种机制。是 Limine 提供的一种机制，用于在 kernel 和 UEFI 之间传递信息。

### 2. 高半 kernel mapping、HHDM 与物理地址为什么不是一回事
HHDM 是 kernel 映射到物理地址的内存区域，用于存储 kernel 代码和数据。物理地址是 kernel 映射到的内存地址，用于存储 kernel 代码和数据。


### 3. response 指针与 `entry->base` 的地址类型为什么不同


### 4. Limine 替换了什么，没有替换什么


### 5. 为什么有 memory map 仍不等于有 allocator
memory map 是说物理内存的大小，不是 allocator 两个东西。

## 仍然不清楚的问题

- request/response、HHDM、协议指针与物理地址、memory map 和 allocator 的边界。

## 导师批改与讲解

> 原始预测保留不改。下面纠正其中写反或不完整的结论，并补齐本章真正需要带入 OS 主线的概念。

### 1. 红灯到底已经证明了什么

原始预测中的两句话写反了：

- `LIMINE:ENTRY` **能够证明已经执行了新 kernel**。这个字符串只会由 `limine_kernel_main()` 写出；静态检查又确认 ELF entry 是高半虚拟地址 `0xffffffff80001000`，所以证据链是“高半 entry 已建立，入口代码已执行”。
- 红灯 **不能证明 memory map 已被正确消费**。恰恰因为没有 `LIMINE:MEMMAP:OK`，它只能证明 consumer 尚未接受 response。

这里要区分“程序整体失败”与“前半段没有发生”：checker 红灯不等于此前一切都没运行。它已经把失败层定位在：

```text
UEFI → Limine → higher-half entry       已成立
response → kernel consumer → OK marker  尚未成立
```

### 2. request/response 不是函数调用，也不是回调

它更像一张放在 ELF 中的“需求单”：

```text
构建时：kernel 把 memory_map_request 数据对象嵌入 ELF
启动时：Limine 扫描对象，把 response 指针写回对象
交接后：kernel 从已经填好的对象中读取结果
```

整个过程没有 `kernel_call_limine()`，Limine 也没有在 kernel 运行后回调我们的函数。UEFI 只在更前面为 Limine 提供启动环境；x86-64 UEFI Boot Services 在 handoff 前已经退出。因此这条数据流是：

```text
kernel ELF request → Limine response → kernel consumer
```

不是“kernel 和 UEFI 互相调用”。

### 3. 高半 kernel mapping、HHDM 和物理地址

这是三件不同的事：

```text
kernel mapping
  让 VA 0xffffffff80001000 指向存放 kernel .text 的某个物理页

HHDM
  为一批物理内存提供统一公式：VA = hhdm_offset + PA

physical address
  RAM/设备在物理地址空间中的编号，例如 PA 0x12345000
```

HHDM 不是专门“存储 kernel 代码和数据”的区域。kernel ELF 有自己的高半 mapping；HHDM 是 kernel 以后访问物理内存的直接窗口。例如假设：

```text
hhdm_offset = 0xffff800000000000
physical     = 0x0000000012345000
```

那么该物理位置在 HHDM 中的虚拟地址是：

```text
0xffff800012345000
```

这个数值与 kernel entry `0xffffffff80001000` 没有必须相等的关系。

静态 `readelf` 中 ELF `PhysAddr` 一栏看起来也很大，并不表示机器存在那个物理地址。对于 Limine protocol，最终物理装载位置由 bootloader 选择；普通 kernel 不应从这一栏猜运行时 PA。需要知道 kernel 的实际装载位置时，应使用协议的 executable-address response。

### 4. 为什么 response 指针能解引用，`entry->base` 不能直接解引用

协议中的指针层次是：

```text
memory_map_request.response       可解引用的虚拟指针
response->entries                 可解引用的虚拟指针
response->entries[i]              可解引用的虚拟指针
entry->base                       物理地址数值
```

前三个已经是 Limine 为 kernel 准备好的虚拟地址。`entry->base` 只是描述某段物理 range 从哪里开始，不能直接强制转换后解引用。以后获得 HHDM offset 后，访问对应 RAM 才会使用：

```text
virtual = hhdm_offset + entry->base
```

也不是每种 memory-map type 都能这样使用；必须遵守当前 base revision 对 HHDM 覆盖范围的规定。

这也解释了为什么代码还要检查 `entry != NULL`：`entries` 是 entry **指针数组**，不是内嵌结构数组。即使官方协议通常保证返回元素非空，consumer 在这份教学合同中仍显式验证，再读取 `entry->type`。

### 5. 为什么不能写死 `entry_count` 或物理地址

原回答说“物理地址由 kernel 生成”不正确。当前 memory map 的底层事实来自 firmware/platform，Limine 再把它规范化为统一 response。结果会随下列因素变化：

- QEMU 配置了多少 RAM、哪些设备和保留洞。
- 从 BIOS 还是 UEFI 启动。
- firmware 与 bootloader 自己占用了哪些区域。
- kernel/modules 实际装载在哪里。

kernel 是 consumer，不是这些物理地址的生产者。它以后会在已有可用 ranges 中选择并分配页，但不能发明 RAM 的物理位置。

### 6. Limine 替换了什么，没有替换什么

Limine 替换的是启动平台工程：

- BIOS/UEFI 差异与启动介质处理。
- 查找 kernel 文件，而不是写死 LBA。
- ELF `PT_LOAD`、`.bss` 和初始 segment 权限。
- 进入 64-bit paging 环境并提供初始栈。
- 把 firmware memory information 规范化为 protocol response。

Limine没有替 kernel 完成 OS 策略：

- 哪些物理页现在归谁所有。
- 正式物理页 allocator。
- kernel-owned page tables、权限与 guard pages。
- 完整 IDT、异常策略、APIC 与 timer。
- 用户态、系统调用、进程、调度、同步和文件系统。

一句话：Limine 把 kernel 送到起跑线，并递交资源说明书；从哪一页开始分配、如何隔离进程，仍由 kernel 决定。

### 7. memory map 为什么不等于 allocator

memory map 不只是“物理内存大小”，而是一张 **带类型的物理地址范围清单**：

```text
[base, base + length) → USABLE / RESERVED / ACPI / BOOTLOADER_RECLAIMABLE / ...
```

它描述启动时的事实，却不会随着 kernel 分配一页而自动变化。allocator 至少还需要：

1. 把 ranges 按 4 KiB 页边界裁剪、对齐。
2. 排除 kernel、modules、仍在使用的 response/stack/page tables 等页。
3. 建立 bitmap、free list 等持久 bookkeeping。
4. `alloc_page()` 时把页从 free 变成 allocated。
5. `free_page()` 时检查所有权并安全归还，防止重复释放。

例如 memory map 只说某段有 1000 个 `USABLE` pages；第一次 `alloc_page()` 后，它仍然说这段是 `USABLE`。只有 allocator 的状态能记住其中哪一页已经借出。这就是第 26 课要建立的“物理页 ownership”。

### 8. 本次实现审查

你的四层判断方向正确，绿灯也真实成立。补充修正了两点：

- response 与 entry 都声明为 `const` 指针，表达 consumer 只读。
- 在访问 `entry->type` 前增加 `entry != NULL`，补齐 entry 指针这一层边界检查。

`found_usable + break` 与“找到后直接 `return true`”语义等价；当前写法可以保留。
