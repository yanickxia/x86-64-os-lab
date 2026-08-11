# 第 21 课：建立可执行的第二阶段 bootloader

## 先修知识

开始前应理解：

- BIOS 只自动加载 LBA 0 的 512-byte boot sector；之后的扇区必须由我们的代码主动读取。
- 第 20 课已经让 stage 1 连续读取 4-sector kernel，并证明 `0x107f8` 的尾部标记进入 RAM。
- 实模式中 `segment:offset` 的物理地址是 `segment × 16 + offset`。
- 近 `CALL` 把下一条指令的 IP 压栈，`RET` 弹出它并恢复执行；第 5 课已经用 `putc` 取证。
- “文件在镜像中”“字节进入 RAM”“CPU 执行这些字节”是三种不同结论。

本课没有新的 CPU 模式，也不要求你编写第二阶段的功能代码。`boot/stage2.asm`、磁盘布局和加载函数都由脚手架提供；你的练习只建立一次真实的跨二进制调用。

指令语义可查 [Intel SDM Volume 2](https://cdrdv2.intel.com/v1/dl/getContent/671110) 的 `CALL` 与 `RET`，NASM flat binary 的 `ORG` 规则可查 [NASM bin output](https://www.nasm.us/doc/nasm09.html#section-9.1)。

## 本课只引入一个机制

stage 1 把独立的 `stage2.bin` 加载到物理地址 `0x8000`，再通过一次近 `CALL` 让 CPU 执行其入口；stage 2 写入独立握手标记后用 `RET` 回到原有启动路径。

```text
stage 1 at 0x7c00
    │
    ├─ INT 13h：LBA 5..6 → RAM 0x8000..0x83ff
    │
    ├─ CALL 0x8000
    │        │
    │        ├─ JMP 0x8008
    │        ├─ [0x7000] = "STAGE2OK"
    │        └─ RET
    │
    └─ 原有 A20 → GDT → paging → C kernel 路径
```

这条 `CALL/RET` 是迁移期接口。后续 E820 和 ELF 加载会逐步进入 stage 2；最终 handoff 不一定返回 stage 1。

## 1. 为什么第二阶段能解除 512 字节限制

第一阶段的位置由 PC BIOS 启动合同固定：LBA 0、512 bytes、末尾 `55 aa`。它最适合只做少量不可避免的工作：建立最小状态、找到启动设备、加载更大的程序并交出控制权。

第二阶段是我们自己放入镜像、自己选择加载地址的普通 flat binary。它不需要在 offset `510` 放签名，也不会被 BIOS 截断为一个扇区。当前先给它 2 sectors / 1024 bytes，以后可以继续扩展或改为由更通用的磁盘接口加载。

```text
stage 1：必须塞进 512 bytes          stage 2：大小由我们的镜像合同决定
┌────────────────────────┐          ┌────────────────────────────┐
│ load kernel / stage 2  │  CALL    │ E820、ELF、boot_info ...  │
│ minimal machine setup  │ ───────▶ │ 可继续增长                 │
└────────────────────────┘          └────────────────────────────┘
```

本课不会立刻把旧代码全部搬走。先证明边界可执行，再迁移职责，比一次重写后无法判断故障发生在哪一层更容易取证。

## 2. 磁盘与 RAM 布局

当前镜像布局为：

| 内容 | LBA | 镜像 byte range | guest physical range |
|---|---:|---:|---:|
| stage 1 / `boot.bin` | 0 | `0x000..0x1ff` | `0x7c00..0x7dff` |
| 4-sector `kernel.bin` | 1..4 | `0x200..0x9ff` | `0x10000..0x107ff` |
| 2-sector `stage2.bin` | 5..6 | `0xa00..0xdff` | `0x8000..0x83ff` |

这些 RAM 范围不重叠：

- 页表使用 `0x1000..0x3fff`。
- stage 2 执行证据使用 `0x7000..0x7007`。
- boot sector 位于 `0x7c00..0x7dff`。
- stage 2 位于 `0x8000..0x83ff`。
- kernel 位于 `0x10000..0x107ff`。
- 保护模式栈从 `0x90000` 向低地址增长。

stage 1 用 `ES:BX = 0x0800:0` 作为 BIOS 缓冲区：

```text
0x0800 × 16 + 0 = 0x8000
```

它从 CHS `0/0/6` 连续读取 sector 6、7；在这个 floppy 镜像中，它们正是 LBA 5、6。

## 3. `stage2.bin` 的入口和两份证据

`boot/stage2.asm` 使用 `ORG 0x8000`，开头为：

```asm
stage2_start:
    jmp short stage2_entry

stage2_magic:
    db 'STAGE2'

stage2_entry:
    mov dword [0x7000], 0x47415453
    mov dword [0x7004], 0x4b4f3245
    ret
```

前 8 个文件字节是：

```text
eb 06 53 54 41 47 45 32
│     └──── "STAGE2" ────┘
└─ jump from 0x8000 to 0x8008
```

文件最后 8 字节是 `S2TAIL!!`。因此检查 stage 2 的起点和尾部，可以证明完整 1024 bytes 已进入 `0x8000..0x83ff`。

但是加载证据仍不能证明执行。只有 CPU 到达 `0x8008`，两条 `MOV` 才会把物理地址 `0x7000..0x7007` 改为：

```text
53 54 41 47 45 32 4f 4b    ASCII "STAGE2OK"
```

QEMU monitor 按 little-endian qword 显示同一批字节时是：

```text
0x4b4f324547415453
```

所以本课有两份相互独立的证据：

```text
0x8000 / 0x83f8 正确  → INT 13h 加载成功
0x7000 = STAGE2OK     → CPU 确实执行了 stage 2
```

## 4. 为什么本课先用 `CALL/RET`

最终 bootloader 通常把控制权单向交给下一阶段或内核，不再返回。但当前 A20、GDT、long mode 和旧内核路径仍位于 stage 1。若本课直接永久 `JMP` 到一个尚未包含这些功能的 stage 2，后面的全部历史回归都会中断。

因此本课先建立一个可逆边界：

```text
stage 1 CALL stage2_start
    → CPU push return IP
    → stage 2 写握手标记
    → RET pop return IP
    → stage 1 继续原路径
```

这不是最终架构，而是迁移脚手架。以后每把一项职责搬到 stage 2，就能沿用握手与旧回归判断迁移前后是否等价。

## 5. 红灯机制（先不要运行）

当前 stage 1 已经调用 `load_stage2`，所以 `stage2.bin` 会完整出现在 RAM。但紧接着保留了三个 NOP：

```asm
; physical 0x7d6b
call load_stage2

; physical 0x7d6e..0x7d70
; RED / TODO (lesson 21): call the loaded stage 2 entry, then let it return.
nop
nop
nop

; physical 0x7d71
jmp .done
```

已知规则：

- 16 位 near `CALL rel16` 长 3 bytes。
- 执行 lesson-21 调用前，`SP=0x7bf4`。
- 调用目标是 `0x8000`；入口的短跳转再到 `0x8008`。
- `stage2_entry` 本身不额外压栈，最后执行 `RET`。

因此红灯会保留旧输出 `HelloPTLKCUR`，stage 2 起点和尾部也已加载；唯一缺失的是 `0x7000` 的执行握手。这里先理解因果，不运行检查。

## 实验前预测

现在已经读完 stage 分工、地址布局、加载/执行证据与当前红灯。在第一次运行 `make check-stage2-handoff` 前，把答案写入 `notes/note-21.md`：

1. `stage2.bin` 的镜像起止 offset 和 guest physical 起止地址分别是什么？尾部 `S2TAIL!!` 的 guest physical 起点是多少？
2. 红灯中 `0x8000`、`0x83f8`、`0x7000` 三处分别应是什么状态？每处能证明什么、不能证明什么？
3. 用正确的 3-byte `CALL` 替换 `0x7d6e..0x7d70` 后，CPU 进入 stage 2 时栈顶地址和值是什么？`RET` 后 `IP/SP` 分别恢复成什么？
4. stage 2 执行后，`0x7000..0x7007` 的 8 个内存字节是什么？为什么 monitor 显示为 `0x4b4f324547415453`？
5. 红灯和绿灯为什么都应输出 `HelloPTLKCUR`？只看这串输出能否证明 stage 2 执行？

错误预测原样保留，实验后另做修正。

## 6. 实验第一步：运行真实红灯

完成预测后运行：

```sh
make inspect-stage2
make disassemble-stage2
make check-stage2-handoff
```

前两项证明 host 文件、镜像位置、入口与指令。第三项启动 QEMU，应得到：

```text
stage2 check: stage 2 bytes are loaded at 0x8000, but its entry never executed
stage2 check: expected execution handshake ... at 0x7000
stage2 check: call STAGE2_LOAD_ADDR from the lesson-21 TODO in boot/boot.asm
stage2 check: actual handshake 0x0000000000000000
```

把实际输出原样记录。红灯如果变成磁盘字节不匹配、旧输出消失或 QEMU 重启，就不是本课期望的单一缺失机制。

## 7. 实验第二步：建立跨二进制调用

打开 `boot/boot.asm`，只修改 lesson 21 的三个 NOP。使用已有的命名常量 `STAGE2_LOAD_ADDR` 建立一次 near `CALL`；不要写死 `0x8000`，也不要修改 stage 2 的握手代码。

约束：

- stage 2 必须通过自己的 `RET` 返回，不能从 stage 1 伪造 `STAGE2OK`。
- 不把 `CALL` 改成永久 `JMP`，因为本课 stage 2 还没有接管后续启动职责。
- 不改变 LBA、加载地址、旧 debug output 或检查器。
- 修改后 3-byte 指令仍必须恰好占据 `0x7d6e..0x7d70`，后面的 `.done` 继续位于 `0x7d73`；`0x7d71` 是跳向 `.done` 的指令地址。

## 8. 绿灯与取证

完成后运行：

```sh
make disassemble-boot
make check-stage2-handoff
make check-multisector-load
make check-exception
```

关键绿灯证据：

```text
stage2 check passed: stage 1 loaded and called stage 2, which returned to the historical boot path
stage2 state: image 0x8000..0x83ff, handshake ... at 0x7000, output='HelloPTLKCUR'
```

反汇编应在 `0x7d6e` 显示一次 3-byte near call；旧 kernel 尾部和异常回归继续通过。

## 9. 这一课完成了什么、还没有完成什么

已经成立：

- stage 2 是独立构建、独立占据磁盘扇区的二进制。
- stage 1 能完整加载它。
- CPU 能跨入 stage 2，并通过独立副作用证明执行。
- stage 2 能按栈上的返回地址回到旧路径。

尚未成立：

- E820 仍未由 stage 2 获取。
- kernel 仍由 stage 1 的简单 CHS 调用加载。
- GDT、分页和 long mode 仍在 stage 1。
- stage 2 还不解析 ELF，也没有构造 `boot_info`。

这些不是隐藏遗漏，而是后续第 22–24 课的显式迁移清单。下一课先让 stage 2 查询 E820，并把物理内存图放入一份有版本和边界的 `boot_info`。

## 10. 简短的 OS 视角

第二阶段的价值不只是“空间更大”，还在于它形成了明确的模块边界：stage 1 只负责抵达一个可靠入口，stage 2 负责收集资源并建立内核运行合同。检查加载证据和执行证据，可以避免把“文件存在”误判成“控制权已经交接”。

## 观察题

1. 为什么 `stage2.bin` 已在 `0x8000` 仍不能推出 CPU 执行过它？
2. `STAGE2`、`S2TAIL!!` 和 `STAGE2OK` 三个标记分别证明哪一层事实？
3. 用栈状态解释本课 `CALL/RET` 为什么能回到原有启动路径。
4. 为什么当前选择 `CALL/RET`，而最终 handoff 更可能使用不返回的跳转？
5. stage 2 已经存在以后，下一课的 E820 代码为什么不应再塞回 boot sector？

## 完成标准

- 预测在第一次真实红灯前完成，错误预测原样保留。
- 只修改 `boot/boot.asm` 中 lesson 21 的三个 NOP。
- `make check-stage2-handoff` 同时证明完整加载、真实执行和返回旧路径。
- 能分别解释磁盘、RAM 字节与执行副作用三层证据。
- `make check-multisector-load` 与 `make check-exception` 继续通过。
- 能明确指出当前 stage 2 只是可执行迁移边界，E820、ELF 和最终单向 handoff 尚待后续课程完成。
