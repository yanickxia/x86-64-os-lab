# 第 17 课阶段考试答题记录

日期：2026.08.10

第一遍独立完成。不查讲义、不运行命令；不会的题写“不确定”。导师审阅前不修改原始答案。

## A. 判断并解释（40 分）

| 题号 | 正确/错误 | 原因                                                                             | 信心（高/中/低） |
| ---- | --------- | -------------------------------------------------------------------------------- | ---------------- |
| A1   | 错误      | org 只是告诉 nasm 起始地址，而不是实际的起始地址。                               | 高               |
| A2   | 正确      | 如果不恰当使用会这样                                                             | 高               |
| A3   | 错误      | LGDT 只是载入，还有其他操作                                                      | 高               |
| A4   | 错误      | 还需要 far jump 一下                                                             | 高               |
| A5   | 错误      | 但是基于GDT 的，历史遗留问题                                                     | 高               |
| A6   | 错误      | 只是根表是 0x1000 的位置，IP才是                                                 | 高               |
| A7   | 错误      | far jump 是重新加载 CS；分页从 CR0.PG=1 后的下一次取指就立即生效。               | 高               |
| A8   | 正确      | 有可能                                                                           | 高               |
| A9   | 错误      | 当前 2 MiB 大页把地址 0 也映射了，空指针可能静默访问物理地址 0。                 | 低               |
| A10  | 错误      | 有类似的机制 ，虽然不记得名字                                                    | 高               |
| A11  | 错误      | 只是禁止中断                                                                     | 高               |
| A12  | 错误      | 不会的，只是一个标记                                                             | 高               |
| A13  | 错误      | 去掉metadata 之类的                                                              | 高               |
| A14  | 正确      | 不一定相同                                                                       | 中               |
| A15  | 错误      | 当前没有未映射的 stack guard，栈越界可能直接破坏其他内存。                       | 高               |
| A16  | 正确      | CALL 压入下一条指令地址，RET 弹出该地址；栈平衡时，返回后的 RSP 应恢复到调用前。 | 高               |
| A17  | 错误      | A20 是地址线 bit 20，解决 1 MiB 回绕，不负责改变执行模式。                       | 高               |
| A18  | 正确      |                                                                                  | 高               |
| A19  | 错误      | 还是需要其他的2个                                                                | 高               |
| A20  | 正确      | IF=0 只屏蔽可屏蔽外部中断，不能阻止 #PF/#DE/#UD 等同步异常，所以仍需要 IDT。     |                  |

## B. 因果链与诊断（60 分）

### B1. 从 reset 到 kernel_start

我的答案：我们所能控制的第一步是 0x7c00 （16 位实模式） 512 字节搬到 0x7c00，DL=启动盘号，-> 利用 INT 13h  读取后面的 512 字节把内核载入，-> 开 A20；LGDT 装 GDTR -> CLI；CR0.PE=1，far jump 到 selector 0x08 进入保护模式 -> 建立页表并打开分页PML4/PDPT/PD -> 设置 CR4.PAE、CR3、EFER.LME、CR0.PG；far jump 到 0x10000 变成 64 的 Long 模式

### B2. 同一个入口字节的五个位置

我的答案：是不同阶段的事情
- elf 地址已确定的 executable
- VMA（Virtual Memory Address）：section 运行时被代码和 symbol 视为什么地址。
- bin： objcopy 已去掉 ELF metadata
- os.img： LBA 1
- guest physical/linear：内存的虚拟地址

### B3. `HelloPTL` 后没有 `K`

我的答案：
1. 磁盘镜像内容，看看 Selection 2 是否在磁盘里面
2. BIOS 加载结果： 是否加载的了 Selection 2 的内容
3. 页表/执行模式： 是否开启了分页，是否开启了保护模式，是否开启了 Long 模式
4. 跳转目标： 是否跳转到了 0x10000

### B4. 开启分页后立即重启

我的答案：载入 cr0 之后，CR0.PE/PG=1 才是对的，然后继续指令执行，就会使用分页来执行，分页需要 PML4/PDPT/PD 来支持虚拟内存，如果没有设计就可能导致错误,下一次取指 → #PF → 无有效 IDT → #DF → triple fault → 重启。

### B5. ELF 检查失败，运行却仍然成功

我的答案：K 和 RIP=0x1000e 正是代码执行过的证据。真正原因是 bootloader 绕过 ELF metadata，固定加载 raw bytes，而相对跳转在整体平移后仍有效。

### B6. 第一段 C 代码“能跑”与“内核已准备好”

我的答案：
- target toolchain 符合目标机器的需要（指令集一致，object/linker 地址也要对）
- 为什么没有 IDT、没有 .bss 清零、没有 stack guard、没有内存图，并不一定阻止这一个极小函数立刻运行，却仍然意味着“内核环境不完整”？ 因为可能不需要这些东西，C 和汇编根本就是可以互相转换的，不使用那些即可

## 第一遍自评

- 最有把握的三题：
- 最不确定的三题：
- 我感觉自己的因果链断在哪一层：

## 导师评分与反馈

- A：28/40
- B：34/60
- 总分：62/100（第一遍诊断分，不含导师补充）
- 结论：加速轨道通过。判断题结论大多正确，主要缺口是把正确结论展开成完整因果链；这些平台细节不再阻塞后续 OS 主线。
- 建议以后按需回看：第 5 课 `CALL/RET`、第 10–11 课分页/long mode、第 14 课 ELF、以及第 15 课的 IDT/C 前缺口。

## 审阅后修正

保留第一遍答案，在这里逐题写“原答案的问题 → 查到的证据 → 修正后的模型”：

### 1. A16：CALL/RET

原判断应改为“正确”。`CALL` 先把下一条指令的地址压栈，再跳到 callee；`RET` 弹出这个返回地址并跳回去。callee 没有额外遗留栈数据时，返回后的 `RSP` 恢复为调用前的值。

### 2. B1：两次模式切换与最终 handoff

```text
CPU reset
  → BIOS 把 boot sector 放到 0x7c00
  → 实模式初始化段和栈，用 INT 13h 把载荷读到 0x10000
  → 开 A20，LGDT
  → CLI，设置 CR0.PE，far jump 到 selector 0x08，进入 32 位保护模式
  → 设置数据段和栈，建立 PML4/PDPT/PD
  → 设置 CR4.PAE、CR3、EFER.LME、CR0.PG
  → far jump 到 selector 0x18，重载 CS 并开始执行 64 位代码
  → 把 0x10000 放入 RAX，JMP RAX 交给独立载荷；这次 CS 不变
```

关键区别：`0x18` 是 selector，负责选择 64 位 code descriptor；`0x10000` 是载荷地址，负责最后的控制权移交。

### 3. B2：同一字节的五套坐标

```text
kernel.elf file offset 0x1000  ← ELF header 和文件对齐占据前面的空间
ELF VMA/LMA 0x10000           ← linker script 的 location counter
kernel.bin offset 0           ← objcopy 去掉 ELF metadata，从最低 loadable section 开始输出
os.img offset 0x200           ← kernel.bin 被放到 LBA 1
guest physical 0x10000        ← BIOS INT 13h 按 ES:BX 把 LBA 1 读到这里
guest linear 0x10000          ← 低 2 MiB 恒等映射，linear 与 physical 数值相同
```

file offset、VMA/LMA、linear address 和 physical address 是不同坐标系，数值相同不表示含义相同。

### 4. B3：`HelloPTL` 后没有 `K` 的证据链

| 顺序 | 查看证据 | 能排除什么 |
|---|---|---|
| 1 | 查看 `os.img` 的 LBA 1 是否以载荷机器码开头 | 排除镜像没有写入或写错扇区 |
| 2 | 查看 guest 物理地址 `0x10000` 的字节是否与 LBA 1 一致 | 排除 BIOS 读盘失败或目标地址错误 |
| 3 | 查看 `CR0/CR3/CR4/EFER/CS` 与页表 | 排除没有进入 long mode、映射缺失或权限错误 |
| 4 | 查看最终 `RIP` 以及 `0x10000` 的反汇编 | 区分没有跳到载荷、跳转目标错误和载荷机器码错误 |
| 5 | 对照 ELF symbols、raw binary 与链接地址 | 定位 ELF→bin 构建或地址契约错误 |

### 5. B4/B5：异常链与 ELF 偶然可运行

- `CR0.PG=1` 后的下一次取指立即查页表；未映射会产生 `#PF`。当前没有有效 IDT，递送异常失败后升级为 `#DF`，再次递送失败形成 triple fault，外部只看到重启。若已有 `#PF` handler，就能读取 fault address/error code 并打印可诊断信息。
- ELF entry、VMA 和 symbols 从 0 开始时，bootloader 仍可能把 `objcopy` 得到的 raw bytes 固定放到 `0x10000` 并跳过去。相对跳转只依赖距离，所以当前载荷仍运行；C 代码或绝对 symbol reference 可能使用 linker 修补的绝对地址，因此不能依赖这种巧合。

### 6. B6：最小 C 调用与完整内核环境

最小调用至少需要：面向 `x86_64-elf` 的 freestanding 编译；把 C object 纳入 linker；汇编入口和 C 遵守同一 SysV ABI；在 `CALL` 前满足栈对齐；关闭 red zone 等不适合内核的编译假设；镜像实际加载覆盖增长后的全部 payload。

这些缺口未被当前小函数使用时，它仍可能运行，但以后会分别出问题：

- 没有 IDT：除零、非法指令或缺页无法诊断，可能 triple fault。
- 没有 `.bss` 清零：未初始化全局变量不满足 C 的零初始化语义。
- 没有 stack guard：深调用或大局部变量可能静默破坏页表/内核数据。
- 没有内存图：物理页分配器不知道哪些 RAM 可用，可能覆盖固件、ACPI 或 MMIO 保留区。

到这里已经足够进入 C。后续遇到异常、内存管理和进程切换时，再把这些机制放回真实 OS 场景中加深理解。

B2:

```

我的答案：是不同阶段的事情
- elf 地址已确定的 executable
- VMA（Virtual Memory Address）：section 运行时被代码和 symbol 视为什么地址。
- bin： objcopy 已去掉 ELF metadata
- os.img： LBA 1
- guest physical/linear：内存的虚拟地址
```
修正之后
```
0x1000：ELF header 与对齐之后的 file offset。
0x10000 VMA/LMA：linker script 决定。
kernel.bin + 0：objcopy 去除 ELF metadata。
os.img + 0x200：LBA 1。
physical 0x10000：BIOS loader。
linear 0x10000：恒等映射。
```
