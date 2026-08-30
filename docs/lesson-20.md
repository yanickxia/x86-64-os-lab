# 第 20 课：让自己的 bootloader 加载多扇区内核

## 先修知识

开始前应理解：

- 第 12 课的 `INT 13h AH=02h` 使用 `AL` 表示连续读取的扇区数。
- 一个磁盘扇区是 512 字节；LBA 0 是 boot sector，内核从 LBA 1 开始。
- BIOS 把内核放到物理地址 `0x10000`，当前 2 MiB 恒等映射覆盖这段地址。
- linker script 决定 raw `kernel.bin` 有多大，bootloader 决定实际从磁盘搬多少字节；二者是两份必须一致的合同。

本课首次看到 NASM 的条件宏：

```asm
%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 4
%endif
```

`%define` 是汇编前的文本常量，不生成 CPU 指令。Makefile 会通过 `-D KERNEL_SECTORS=4` 提供同名值；上面的默认值让源文件单独组装时仍有明确行为。参考：[NASM Preprocessor](https://www.nasm.us/doc/nasmdoc4.html)。

## 本课只引入一个机制

让现有 BIOS 读盘调用一次加载连续 4 个扇区，而不是只加载内核的第一个扇区。

```text
os.img
LBA 0        LBA 1        LBA 2        LBA 3        LBA 4
boot sector  kernel[0]    kernel[1]    kernel[2]    kernel[3]
                 │             │             │             │
                 └──────── INT 13h, AL=4 ─────────────────┘
                               │
                               ▼
RAM       0x10000 .................................. 0x107ff
```

这不是 Limine，也不是一条新的替代主线；它是在继续完善我们自己的 bootloader。

## 1. 我们自己的 bootloader 为什么还能继续

当前 boot sector 仍严格为 512 字节，签名仍在 offset `0x1fe`，实际代码结束后还有约 133 字节填充空间。因此“切换 Limine”不是因为已经放不下任何指令，而是之前为了加速 OS 主线做出的课程选择。

这个选择现在延后。当前 loader 还有四项值得完整走一遍的合同：

1. 能加载超过一个扇区，而不是把内核锁死在 512 字节。
2. 形成 stage 1 / stage 2，摆脱 boot sector 容量和简单 CHS 读取的限制。
3. 读取 E820 内存图，通过明确的 `boot_info` 交给 C。
4. 按 ELF `PT_LOAD` 搬运 segment、清零 `.bss`、建立内核栈并按 ABI 交接。

完成这些以后再切 Limine。到那时 Limine 是一份成熟实现的替换与对照，而不是突然出现的黑盒。

## 2. 当前的单扇区限制来自哪里

之前存在两个互相配合的 `512`：

```text
kernel/linker.ld                  boot/boot.asm
.text 被补到 0x200 字节           mov al, 0x01
          │                                │
          ▼                                ▼
kernel.bin 恰好 1 sector          BIOS 恰好读取 1 sector
```

这不是 ELF、CPU 或 C 的固有限制，只是我们自己定义的加载协议。现在课程基础设施已经把 `kernel.bin` 扩大为：

```text
KERNEL_SECTORS    = 4
KERNEL_IMAGE_BYTES = 2048 = 0x800
```

linker 在最后 8 字节放入 `LOAD4SEC` 标记。因此即使前 512 字节足以继续执行旧内核，只有真正读取全部 4 个扇区，物理地址 `0x107f8` 才会出现这个标记。

## 3. 三套地址如何对应

内核从镜像 LBA 1 开始，加载到物理地址 `0x10000`。对 kernel offset `x`：

```text
os.img file offset = 0x200 + x
guest physical     = 0x10000 + x
```

四个扇区的完整布局是：

| 对象 | 起点 | 最后一个字节 |
|---|---:|---:|
| `kernel.bin` offset | `0x000` | `0x7ff` |
| `os.img` offset | `0x200` | `0x9ff` |
| guest physical | `0x10000` | `0x107ff` |

尾部标记从 kernel offset `0x7f8` 开始，所以：

```text
kernel.bin offset   0x7f8
os.img offset       0x200 + 0x7f8 = 0x9f8
guest physical      0x10000 + 0x7f8 = 0x107f8
```

运行 `make inspect-kernel-span` 会显示文件中的 2048 字节和尾部标记。它只能证明 host 文件与磁盘镜像正确，不能证明 BIOS 已把尾部搬进 guest RAM。

## 4. `AL=4` 在本实验中为什么安全

当前 floppy 每条 track 有 18 个扇区，CHS sector 从 1 开始。读取从 CHS `0/0/2` 开始的 4 个扇区，会覆盖 sector 2、3、4、5，没有跨过 track 边界：

```text
AL = 1  → 只读 sector 2
AL = 4  → 连续读 sector 2..5
```

BIOS 把数据连续写入 `ES:BX = 0x1000:0` 开始的缓冲区，因此读取长度为：

```text
4 × 512 = 2048 = 0x800 bytes
```

本课仍使用已学过的 CHS 接口，目的是先把“产物大小必须与加载长度一致”证明清楚。它不是最终通用磁盘加载方案：跨 track、内核继续增长以及不同启动设备会在后续 stage 1 / stage 2 课程中统一处理。

## 5. 红灯机制（先不要运行）

构建系统现在已经生成 4-sector `kernel.bin`，但 `load_kernel` 仍故意保留旧值：

```asm
mov ah, 0x02
; RED / TODO (lesson 20): load the complete KERNEL_SECTORS-sector image.
mov al, 0x01
mov ch, 0x00
mov cl, 0x02
mov dh, 0x00
int 0x13
```

所以红灯状态是：

```text
磁盘镜像包含 4 sectors
BIOS 实际只读取 1 sector
前 512 字节内的旧内核仍能运行
最后一个 sector 的 LOAD4SEC 没有进入 RAM
```

当前代码、IDT 和异常处理所需数据都位于物理地址 `0x10000..0x101ff`，所以完整输出仍然可能是 `HelloPTLKCUR`。这正是本课最重要的诊断点：**程序能运行，不代表整个加载合同已经成立。**

这里仅说明红灯成因，先不要运行检查。

## 实验前预测

现在已经读完产物大小、地址对应、BIOS 扇区计数和红灯代码。
在第一次运行 `make check-multisector-load` 前，把答案写入 `notes/05-C内核与Bootloader毕业/note-20.md`：

1. 红灯中的 `AL=1` 会向 RAM 写入多少字节？物理起止地址分别是什么？
2. 红灯是否仍会输出 `HelloPTLKCUR`？物理地址 `0x107f8` 应是什么状态？分别说明原因。
3. 加载 4 个扇区后，`kernel.bin` 最后一个字节对应的镜像 offset 和 guest physical address 分别是多少？
4. `make check-exception` 即使通过，为什么仍不能证明 4-sector 内核已被完整加载？
5. 从 CHS sector 2 连续读取 4 个扇区会访问哪些 sector？本实验为什么没有跨 track？

错误预测原样保留，实验后在“我的解释”中修正。

## 6. 实验第一步：运行真实红灯

完成预测后运行：

```sh
make inspect-kernel-span
make check-multisector-load
```

第一条命令应证明 `kernel.bin` 与 `os.img` 中都存在尾部 `LOAD4SEC`。第二条会启动 QEMU 并读取 guest 物理地址 `0x107f8`，当前应得到干净红灯：

```text
multi-sector check: the kernel starts correctly, but its last sector was not loaded
multi-sector check: expected tail ... at physical 0x107f8
multi-sector check: load all KERNEL_SECTORS in boot/boot.asm
multi-sector check: actual tail ...
```

把实际输出原样记录下来。检查器同时要求旧输出仍为 `HelloPTLKCUR`，以排除“为了让尾部出现却破坏了内核入口”的错误修复。

## 7. 实验第二步：让读取长度服从合同

打开 `boot/boot.asm`，只修改 lesson 20 的单个 TODO：让 `AL` 使用已经提供的 `KERNEL_SECTORS`，不要再次写死另一个数字。

约束：

- 不修改起始 CHS `0/0/2`。
- 不移动加载地址 `0x10000`。
- 不修改 linker 的尾部标记或检查脚本。
- 不通过额外 `INT 13h` 读一个特定尾扇区来迎合检查；本课机制是一次连续读取完整载荷。

这里没有新的汇编指令，只有“立即数应来自统一合同”这一工程约束。

## 8. 绿灯与取证

完成后运行：

```sh
make check-multisector-load
make check-image
make check-kernel-elf
make check-exception
```

绿灯应同时证明：

- `kernel.bin` 为 2048 字节，镜像中 LBA 1 开始的 4 个扇区与它完全一致。
- `LOAD4SEC` 出现在 guest 物理地址 `0x107f8`。
- ELF entry 和旧内核 symbols 仍位于 `0x10000` 开始的地址空间。
- `#UD → C handler → IRETQ` 的旧行为仍输出 `HelloPTLKCUR`。

## 9. 明确的 bootloader 毕业点

“没有任何 bootloader 遗漏”如果按生产标准理解是不可能的：UEFI、Secure Boot、文件系统、网络启动、图形模式、各种硬件兼容足以构成另一个项目。本课程采用更可验证的边界——**与后续内核直接相关的启动合同没有黑盒**。

切换 Limine 前固定完成以下路线：

| 课程 | 自己的 loader 要闭环的合同 |
|---|---|
| 第 20 课 | 多扇区载荷：磁盘长度与 RAM 中实际长度一致 |
| 第 21 课 | stage 1 / stage 2：解除 512 字节代码空间和简单 CHS 的长期限制 |
| 第 22 课 | E820 + `boot_info`：把真实物理内存布局传给 C |
| 第 23 课 | ELF `PT_LOAD`、`.bss`、内核栈和 ABI handoff |
| 第 24 课 | bootloader 毕业复盘：逐项取证，并列出有意不实现的生产功能 |
| 第 25 课 | 对照并切换 Limine，之后进入物理页分配器 |

到第 25 课时，我们会把自己的 handoff struct 与 Limine response 逐字段对应。切换只是替换实现，不会突然引入未解释的资源、地址或执行环境。

## 10. 简短的 OS 视角

内核必须相信 loader 所声明的加载范围。如果 loader 少读了扇区，而恰好入口代码都在第一扇区，错误会潜伏到以后第一次调用尾部函数或访问尾部数据时才爆发。用尾部标记检查完整范围，是把这种延迟故障提前变成启动期不变量。

## 观察题

1. 解释为什么 `kernel.bin` 是 2048 字节、旧内核仍能在只读 512 字节时运行，这两个事实并不矛盾。
2. `KERNEL_SECTORS` 同时影响哪一侧？`KERNEL_IMAGE_BYTES` 又影响哪一侧？谁负责检查它们最终一致？
3. 为什么检查尾部标记比只检查 `HelloPTLKCUR` 更能证明加载完整性？
4. 本课的 `AL=4` 为什么仍不是可扩展的最终 loader？
5. 用一句话说明第 20–24 课定义的 bootloader 毕业边界。

## 完成标准

- 在第一次运行红灯前完成五项预测，错误预测原样保留。
- 只修改 `boot/boot.asm` 中 lesson 20 的单个 TODO。
- `make check-multisector-load` 证明 4 个扇区和尾部标记确实进入 RAM。
- `make check-kernel-elf` 与 `make check-exception` 继续通过。
- 能区分“文件中存在”“第一扇区代码能运行”和“完整载荷已进入 RAM”三种不同证据。
- 知道课程将在第 24 课完成 bootloader 毕业检查、第 25 课才切换 Limine。
