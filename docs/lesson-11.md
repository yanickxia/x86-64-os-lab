# 第 11 课：激活分页并进入 64 位 long mode

## 先修知识

开始前应能用前两课的证据说明：

- CPU 已处于 32 位保护模式，`CR0.PE=1`，当前 `CS=0x08` 且 QEMU 显示 `CS32`。
- `DS=ES=SS=0x10`，flat data descriptor 的 base 为 0。
- 物理地址 `0x1000/0x2000/0x3000` 已放置 PML4、PDPT 和 PD。
- `PML4[0]=0x2003`、`PDPT[0]=0x3003`、`PD[0]=0x0083` 形成低 2 MiB 恒等映射。
- 当前代码约在 `0x7cf0`，栈顶为 `0x90000`，两者都落在低 2 MiB。

本课首次使用 `CR4`、`CR3`、model-specific register（MSR）、`RDMSR/WRMSR`、`EFER` 与 `bits 64`。练习前会给出寄存器位、读写约定、顺序约束与反汇编证据。

权威参考：

- [Intel SDM Volume 3A](https://cdrdv2.intel.com/v1/dl/getContent/671190)，查找 “IA-32e Mode”、`CR0`、`CR3`、`CR4.PAE` 和 “4-Level Paging”。
- [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110)，查找 `MOV—Control Registers`、`RDMSR`、`WRMSR` 与 `JMP`。
- [AMD64 Architecture Programmer's Manual, Volume 2](https://docs.amd.com/v/u/en-US/24593_3.44_APM_Vol2)，查找 “Long-Mode Activation” 与 `EFER`。

## 本课只引入一个机制

让 CPU 第一次真正使用上一课的页表，并进入 64-bit mode：

```text
CR4.PAE=1
    ↓
CR3=0x1000
    ↓
EFER.LME=1
    ↓
CR0.PG=1  → EFER.LMA 自动变成 1
    ↓
far jump to selector 0x18 → CS64
```

最终证据必须同时满足：

```text
CR0 = 0x80000011  PE=1, PG=1
CR3 = 0x00001000  PML4 root
CR4 = 0x00000020  PAE=1
EFER = 0x0000000000000500  LME=1, LMA=1
CS = 0x0018 ... CS64
```

本课不会引入 C、ELF、高半内核、IDT 或用户态。进入 64 位后只输出一个字符并停住，把变量严格限制在模式切换本身。

## 1. 为什么没有一条 `enter_long_mode` 指令

x86-64 long mode 是多代机制叠加后的结果：

1. 80386 已用 `CR0.PG` 控制传统分页。
2. 后来的 PAE 用 64 位页表 entry 扩展物理地址和权限表达能力，由 `CR4.PAE` 选择。
3. AMD64 在兼容旧 x86 的前提下加入 `EFER.LME`，声明软件希望激活 long mode。
4. `CS` descriptor 的 `L` 位再决定当前指令流按 64 位还是兼容模式解码。

因此 CPU 必须分别知道：

```text
使用哪一种页表格式？          CR4.PAE
根页表在哪里？                CR3
是否请求 long mode？          EFER.LME
是否真的开始分页？            CR0.PG
当前代码按 32 还是 64 位解码？ CS descriptor 的 L/D
```

这些状态各有独立用途，硬件没有把它们压成一个按钮。顺序错了时，CPU 可能产生 `#GP`、取指时产生 `#PF`，或因我们尚未建立 IDT 而继续演化为 triple fault/reset。

## 2. 第一步：设置 `CR4.PAE`

`CR4` 保存体系结构扩展功能开关。PAE 是 bit 5：

```text
CR4.PAE = 1 << 5 = 0x00000020
```

本课源码已定义：

```asm
CR4_PAE equ 1 << 5
```

`EQU` 右侧的 `<<` 是 NASM 的汇编期左移运算。它不会让 CPU 在运行时执行移位；`CR4_PAE` 出现在指令中时，NASM 直接代入 `0x20`。

与修改 `CR0.PE` 一样，控制寄存器应使用读—改—写：

```asm
mov eax, cr4
or eax, CR4_PAE
mov cr4, eax
```

不能直接假定 CR4 其他位都是 0。我们只拥有修改 PAE 这一位的意图，不应顺手清掉未来由固件或前序代码设置的其他功能。

在 IA-32e 激活流程中，`CR4.PAE=1` 告诉 CPU：打开分页时要按 PAE/IA-32e 所需的 64 位 entry 格式解释页表，而不是旧式 32 位两级页表。

## 3. 第二步：把 PML4 的物理地址装入 `CR3`

上一课只是在 RAM 中构造了三张表，CPU 还不知道根在哪里。`CR3` 建立这个联系：

```text
CR3 = physical address of PML4 = 0x00001000
```

对应操作由两个步骤组成：先把普通数值放进通用寄存器，再写控制寄存器。

```asm
mov eax, PML4_ADDR
mov cr3, eax
```

这里写入的是 PML4 所在物理页的地址，不是 `PML4[0]` 的值：

```text
CR3       = 0x1000  根表本身位于哪里
PML4[0]   = 0x2003  第一个 entry 指向哪里以及它的 flags
```

虽然两者都与 PML4 有关，却处于页表遍历的不同位置。CPU 从 CR3 得到 physical `0x1000`，再读取那里的 entry `0x2003`。

加载 CR3 也与 TLB 管理有关；将来切换地址空间时会再次遇到它。本课尚未开启 paging，因此当前加载主要是为随后的首次 page-table walk 指定根。

## 4. 第三步：通过 MSR 设置 `EFER.LME`

### 4.1 MSR 不是内存地址，而是一组“带编号的 CPU 寄存器”

`EAX`、`CR0` 等寄存器可以直接写进指令编码；但处理器后来增加了大量系统功能，不可能不断为每项功能发明新的 `CR5/CR6/...` 和专用指令。x86 因此提供了一组 model-specific registers（MSR）：它们位于 CPU 内部，每个由一个 32 位编号标识。

可以把接口想成一个 CPU 内部的寄存器柜：

```text
MSR number 0x00000010  → IA32_TIME_STAMP_COUNTER
MSR number 0xc0000080  → IA32_EFER
MSR number ...         → 其他系统状态
```

这个比喻只用于理解“编号选择”：MSR 不是 RAM，也不是 I/O port。

- `0xc0000080` 不是 physical/linear address，不经过 paging。
- 源码不写 `[0xc0000080]`，因为方括号表示内存操作数。
- CPU 用 `ECX` 的数值选择某个 MSR，再用专门指令传送它的内容。

AMD64 最初把这个寄存器称为 EFER（Extended Feature Enable Register）；Intel 64 文档通常写作 `IA32_EFER`。这里指的是同一个体系结构 MSR，编号都是：

```text
IA32_EFER_MSR = 0xc0000080
```

一定要分清“寄存器编号”和“寄存器内部的位”：

```text
0xc0000080  选择整个 IA32_EFER 寄存器
bit 8       IA32_EFER 内部的 LME 字段
bit 10      IA32_EFER 内部的 LMA 字段
```

因此“IA32_EFER 是 bit 8”是错误的：IA32_EFER 是完整的 64 位寄存器；LME 才是其中的 bit 8。

### 4.2 为什么指令没有写操作数

`RDMSR` 和 `WRMSR` 看起来只有一个单词：

```asm
rdmsr
wrmsr
```

因为它们的操作数由体系结构固定，不需要、也不允许在源码里另写：

```text
                        63                         32 31                          0
                       +-----------------------------+-----------------------------+
MSR 的 64 位内容        |             EDX             |             EAX             |
                       +-----------------------------+-----------------------------+

ECX = MSR number

RDMSR: selected MSR  ───────────────→ EDX:EAX
WRMSR: EDX:EAX       ───────────────→ selected MSR
```

它们不是一对自动完成修改的指令：

- `RDMSR` 只把 CPU 内部的值复制出来。
- 普通的 `OR` 只修改这个寄存器副本。
- `WRMSR` 才把修改后的副本写回 CPU 内部状态。

### 4.3 EFER 中的 LME 与 LMA 是“请求”和“结果”

本课关注 EFER 的两个位：

| 位 | 名称 | 谁设置 | 含义 |
| --- | --- | --- | --- |
| 8 | LME | 软件 | Long Mode Enable：允许满足其他条件时激活 long mode |
| 10 | LMA | CPU | Long Mode Active：CPU 报告 IA-32e mode 当前已经 active |

对应掩码：

```text
EFER.LME = 1 << 8  = 0x00000100
EFER.LMA = 1 << 10 = 0x00000400
```

把它理解成“武装”和“已触发”更直观：

```text
LME=0, LMA=0
    long mode 未被允许

软件写 LME=1，但 CR0.PG 仍为 0
    LME=1, LMA=0
    已武装，还未 active

PAE=1、页表有效、LME=1，此时把 CR0.PG 从 0 改成 1
    LME=1, LMA=1
    CPU 自动置 LMA，IA-32e mode active
```

软件设置的是 LME，不能直接设置只读的 LMA。最终看到 `EFER=0x500`，不是因为代码 OR 了 `0x500`，而是：

```text
软件设置 LME： 0x100
CPU 报告 LMA： 0x400
                 -----
最终 EFER：      0x500
```

即使 `LMA=1`，当前代码也不一定已是 `CS64`。刚打开 PG 时，当前 CS 仍可能是 `L=0, D=1` 的 32 位 descriptor，CPU 暂时运行 IA-32e compatibility mode；第 6 节的 far jump 才会加载 `L=1` 的 CS。

### 4.4 逐条模拟本课的四条指令

安全的读—改—写形状是：

```asm
mov ecx, IA32_EFER_MSR
rdmsr
or eax, EFER_LME
wrmsr
```

当前 QEMU 红灯显示初始 `EFER=0`。逐条执行时：

| 执行后 | ECX | EDX | EAX | CPU 内真正的 EFER |
| --- | --- | --- | --- | --- |
| 初始 | 未知 | 未知 | 未知 | `0x0000000000000000` |
| `mov ecx, IA32_EFER_MSR` | `0xc0000080` | 未改变 | 未改变 | 仍为 `0x0` |
| `rdmsr` | `0xc0000080` | `0x00000000` | `0x00000000` | 仍为 `0x0` |
| `or eax, EFER_LME` | `0xc0000080` | `0x00000000` | `0x00000100` | **仍为 `0x0`** |
| `wrmsr` | `0xc0000080` | `0x00000000` | `0x00000100` | 变为 `0x0000000000000100` |

最容易忽略的是第四列与第五列：`OR` 只改 EAX，并没有隔空修改 EFER；必须执行 `WRMSR`，真正的 EFER 才从 0 变成 `0x100`。

下一步再设置 `CR0.PG` 后，CPU 自动令 LMA=1，QEMU 最终才报告：

```text
EFER=0000000000000500
```

### 4.5 为什么必须先读再改，不能直接写 `0x100`

EFER 除了 LME/LMA，还可能包含 `SCE`（系统调用扩展）、`NXE`（禁止执行页）等状态。假设以后进入本课时 EFER 已经是：

```text
EFER = 0x00000801  SCE=1, NXE=1
```

正确的读—改—写得到：

```text
0x00000801 OR 0x00000100 = 0x00000901
```

原来的 SCE/NXE 得以保留。如果跳过 `RDMSR`，直接令 `EAX=0x100、EDX=0` 再 `WRMSR`，就会把其他已设置的功能清零。当前 QEMU 恰好报告 EFER 初值为 0，不代表 bootloader 可以把这个偶然状态写进假设。

`LME` 位于低 32 位，所以只需对 EAX 做 OR；`RDMSR` 读出的 EDX 必须原样保留，随后 `WRMSR` 才能写回完整的 64 位值。

### 4.6 六个常见错误

1. `mov eax, IA32_EFER_MSR`：错误。MSR 编号必须放在 ECX，不是 EAX。
2. `or ecx, EFER_LME`：错误。这会把“柜门编号”改成另一个编号，而不是修改柜内的 EFER。
3. 在 `RDMSR` 前直接 `or eax, EFER_LME`：错误。EAX 还不是 EFER 的当前值。
4. 忘记 `WRMSR`：只修改了 EAX 副本，真正的 EFER 没变化。
5. 把期望值写成 `EFER=0x100`：只描述已设置 LME、尚未激活；本课最终 active 状态应为 `0x500`。
6. 尝试手动 OR `EFER_LMA`：错误。LMA 是 CPU 管理的只读 active 状态。

此外，`RDMSR/WRMSR` 是特权指令；ring 3 执行、ECX 选择不存在的 MSR，或写入某些保留位，都可能产生 `#GP`。当前 bootloader 运行在 ring 0，且 QEMU 的 x86-64 CPU 提供 IA32_EFER，因此可以使用。

### 4.7 本节自检

先不看实现，尝试口头回答：

1. 执行 `RDMSR` 后，改变的是 EFER 还是 `EDX:EAX`？
2. 执行 `OR EAX, 0x100` 后，为什么 QEMU 内部的 EFER 仍未改变？
3. `ECX=0xc0000080` 与 `EAX bit 8=1` 分别在表达什么？
4. 为什么执行 `WRMSR` 后 EFER 先是 `0x100`，最终检查却看到 `0x500`？
5. 若读取到 `EDX:EAX=0x00000000:00000801`，设置 LME 后应写回什么？

## 5. 第四步：设置 `CR0.PG`

Paging Enable 是 CR0 bit 31：

```text
CR0.PG = 1 << 31 = 0x80000000
```

进入本课前：

```text
CR0 = 0x00000011  PE=1，且保留了复位已有的 ET bit
```

只设置 PG 后：

```text
0x00000011 OR 0x80000000 = 0x80000011
```

仍然必须读—改—写，而不能执行“把 CR0 直接改成 `0x80000000`”：那会错误清掉已经工作的 `PE` 等位。

当 CPU 在 `PE=1、PAE=1、LME=1` 的前提下看到 `PG` 从 0 变成 1，会：

1. 开始用 CR3 指向的 PML4 翻译 linear address。
2. 自动令只读状态位 `EFER.LMA=1`。
3. 激活 IA-32e mode。

因此绿灯的 EFER 是：

```text
LME | LMA = 0x100 | 0x400 = 0x500
```

软件不能直接把 LMA 写成 1；它是 CPU 根据控制状态报告的结果。

## 6. 打开 PG 后为什么还不是 `CS64`

执行 `mov cr0, eax` 打开 PG 后，IA-32e mode 已 active，但当前 CS 仍缓存着第 9 课的 32 位 code descriptor：

```text
selector 0x08 → GDT[1] → L=0, D=1 → CS32
```

这时处理器处于 IA-32e 的 compatibility mode，仍按 32 位规则解码当前指令流。还需要 far jump 加载一个 `L=1` 的 code descriptor。

脚手架已把 GDT 从三项扩展到四项：

```text
GDT[0]  null
GDT[1]  32-bit code   selector 0x08
GDT[2]  flat data     selector 0x10
GDT[3]  64-bit code   selector 0x18
```

selector 仍按旧公式计算：

```text
(index << 3) | (TI << 2) | RPL
=(3 << 3) | 0 | 0
=0x18
```

64 位 code descriptor 的关键组合是：

```text
L=1   64-bit code
D=0   不能同时使用 32 位默认操作数属性
```

脚手架中的原始值为：

```asm
dq 0x00af9a000000ffff
```

其中 access byte `0x9a` 表示 present、ring 0、code、execute/read；flags nibble `0xa` 表示 `G=1, D=0, L=1, AVL=0`。64-bit mode 忽略普通 code segment 的 base 和 limit，但 selector、权限和 `L` 位仍然重要。

最后使用：

```asm
jmp CODE64_SELECTOR:long_mode_entry
```

far jump 同时加载 `CS=0x18` 并修改指令地址。CPU 从 GDT[3] 读取 `L=1` 后，才开始按 64 位规则解码 `long_mode_entry`。

本课布局中，32 位 far jump 的目标是 selector `0x18`、offset `0x00007d30`。x86 小端序会影响机器码中字节顺序；请先自己预测，再用 `make disassemble-boot` 核对。

## 7. `bits 64` 仍然不是 CPU 指令

源码在目标处写：

```asm
bits 64
long_mode_entry:
    mov al, 'L'
    out 0xe9, al
```

`bits 64` 只告诉 NASM 后面的代码应按 64 位默认规则编码，不生成机器码。真正令 CPU 使用 64 位解码的是：

```text
EFER.LMA=1 + CS descriptor L=1
```

这与第 9 课的 `bits 32` 完全同理：汇编器的编码假设必须和 CPU 运行时模式吻合。后续课程开始使用 64 位寄存器和 REX prefix 时，这个一致性会更加明显。

## 8. 为什么恒等映射在这一刻不可替代

设置 `CR0.PG` 的指令在低地址执行。PG 生效后，下一次取指立即使用页表：

```text
linear 0x00007dxx
  → PML4[0]
  → PDPT[0]
  → PD[0, PS=1]
  → physical 0x00007dxx
```

随后 far jump 的目标 `0x7d30`、64 位入口、栈 `0x90000` 也都位于该 2 MiB leaf 内。恒等映射让打开分页前后的物理代码和栈保持同一位置，无需同时搬代码和重算跳转目标。

如果 PML4 entry 错、CR3 指向错、P/RW/PS 位错或当前 RIP 未映射，CPU 会在切换中立刻 fault。由于目前没有 IDT 和 page-fault handler，外部表现通常只是 QEMU reset 或停止输出。这也是为什么上一课先单独验证页表内容，而不是把所有错误混在一次模式切换里。

## 9. 第一次 page-table walk 为什么会修改 entry

上一课在 paging 尚未开启时观察到：

```text
PML4[0] = 0x2003
PDPT[0] = 0x3003
PD[0]   = 0x0083
```

当 CPU 真正使用这些 entry 完成地址翻译，会自动设置 Accessed（A，bit 5）以记录“这条路径被访问过”：

```text
A = 1 << 5 = 0x20

0x2003 | 0x20 = 0x2023
0x3003 | 0x20 = 0x3023
0x0083 | 0x20 = 0x00a3
```

因此 long-mode 绿灯后再次查看物理页表，很可能看到 `0x2023/0x3023/0x00a3`。地址部分、P/RW/PS 都没变；这是硬件留下的使用痕迹，不是程序破坏了页表。

`make check-page-tables` 会接受 A=0 或 A=1，因为它既要在红灯的“尚未 page walk”状态运行，也要在绿灯的“已经 page walk”状态运行。后续操作系统会利用 Accessed/Dirty 位辅助页面回收与写回决策。

## 10. 红灯为什么也输出 `HelloPTL`

红灯的 `enable_long_mode` 故意只做：

```asm
mov al, 'L'
out 0xe9, al
jmp $
```

所以红灯和绿灯的 debug console 都是：

```text
HelloPTL
```

但红灯寄存器是：

```text
CR0=00000011
CR3=00000000
CR4=00000000
EFER=0000000000000000
CS =0008 ... CS32
```

绿灯必须是：

```text
CR0=80000011
CR3=00001000
CR4=00000020
EFER=0000000000000500
CS =0018 ... CS64
```

和第 9 课一样，输出字符只能证明控制流到过某段代码，不能证明 CPU 模式。`make check-long-mode` 以控制寄存器、EFER 和 CS descriptor cache 为最终证据。

## 11. 固定地址布局发生了什么变化

第 8 课的三项 GDT 占 `0x7c50..0x7c67`，原 GDTR 伪描述符紧跟在 `0x7c68`。本课增加第 4 个 descriptor 后，它恰好占用 `0x7c68..0x7c6f`；而 `0x7c70` 必须继续留给旧课的保护模式切换代码。

因此脚手架保留 GDT base 与所有旧代码入口，只把 6 字节 GDTR 伪描述符搬到空闲的 `0x7ce0`：

```text
0x7c50..0x7c6f  four-entry GDT
0x7c70           enter_protected_mode
0x7c90           protected_mode_entry
0x7cb0           setup_page_tables
0x7ce0           gdt_descriptor
0x7cf0           enable_long_mode
0x7d30           long_mode_entry
```

`LGDT [gdt_descriptor]` 的机器码因此包含新地址 `0x7ce0`，但 GDTR 的 base 仍是 `0x7c50`；两者不要混淆。GDT 有 4 个 8 字节 entry，所以 limit 变为：

```text
4 × 8 - 1 = 31 = 0x1f
```

## 实验前计算

修改代码前，把以下结果写入 `notes/note-11.md`：

1. `CR4.PAE` 的 bit 编号与掩码。
2. PML4 的物理地址，以及加载 CR3 后的期望值。
3. `IA32_EFER` 的 MSR 编号；`LME` 与 `LMA` 各自的 bit 和掩码。
4. 当前 `CR0=0x00000011`，设置 PG 后应得到什么值。
5. 64 位 code descriptor 的 index、TI、RPL 与 selector。
6. 为什么 64 位 code descriptor 必须 `L=1, D=0`。
7. far jump 的 offset、selector，以及预计的 7 个机器码字节。
8. 绿灯时 `CR0/CR3/CR4/EFER/CS` 的完整期望值。

## 红灯

先不要修改 `enable_long_mode`。运行：

```sh
make check-long-mode
make disassemble-boot
make inspect-gdt
```

预期 `check-long-mode` 失败，但失败信息应干净地显示：

```text
CR0=00000011 ... CR3=00000000 CR4=00000000
CS =0008 ... CS32
EFER=0000000000000000
```

把原始输出抄进笔记。`HelloPTL` 已出现不是失败噪声，而是本课刻意设置的对照实验。

## 练习

只替换 `enable_long_mode` 中输出 `L` 并原地循环的红灯代码。按本课说明组合以下五步：

1. 读—改—写 `CR4.PAE`。
2. 把 `PML4_ADDR` 装入 `CR3`。
3. 用 `RDMSR/WRMSR` 读—改—写 `EFER.LME`。
4. 读—改—写 `CR0.PG`。
5. far jump 到 `CODE64_SELECTOR:long_mode_entry`。

不要修改：

- 三张页表及其地址。
- GDT descriptor 值和 `long_mode_entry`。
- debug console 的期待值。
- 测试脚本中的寄存器断言。
- 固定地址填充。

完成后运行：

```sh
make check-long-mode
make check-page-tables
make check-protected
make check-gdt
make check-a20
make check-debugcon
make check-call
make check-segments
make check-boot
make disassemble-boot
```

## 观察题

1. 为什么 IA-32e mode 要求 `CR4.PAE=1`，而不是只设置 `CR0.PG`？
2. `CR3=0x1000` 与 `PML4[0]=0x2003` 各自表示什么？
3. 为什么要先准备有效页表、设置 PAE 和 LME，最后才打开 PG？
4. `EFER.LME` 与 `EFER.LMA` 有什么区别？谁负责设置 LMA？
5. `RDMSR/WRMSR` 为什么使用 `ECX` 与 `EDX:EAX`？为什么只 OR EAX 仍要保留 EDX？
6. 打开 `CR0.PG` 后为什么还要 far jump？`CS.L` 改变了什么？
7. `bits 64` 与真正进入 64-bit mode 有什么区别？
8. 低 2 MiB 恒等映射保护了切换瞬间的哪些访问？
9. page-table walk 为什么可能把三个 entry 改成 `0x2023/0x3023/0x00a3`？哪些部分没有改变？
10. 为什么红灯与绿灯同样输出 `HelloPTL`，却只有一个处于 long mode？
11. 进入 64-bit mode 后，为什么后续内存管理会主要围绕 paging，而不是普通 segmentation？

## 完成标准

- 先记录一次只输出 L、但寄存器仍为 32 位状态的预期红灯。
- `make check-long-mode` 报告 `CR0.PG=1、CR3=0x1000、CR4.PAE=1、EFER.LME=LMA=1、CS64`。
- 能逐步解释每个控制位的职责与设置顺序。
- 能解释打开 PG 与 far jump 分别改变 IA-32e active 状态和当前代码解码模式。
- 能从 selector、offset 和小端序核对 far jump 的机器码。
- 页表、保护模式、GDT、A20、字符串、调用栈、段寄存器与启动扇区测试全部回归通过。
