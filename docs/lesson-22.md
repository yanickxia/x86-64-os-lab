# 第 22 课：用 E820 把物理内存图交给 C 内核

## 先修知识

开始前应理解：

- stage 2 仍在 16 位实模式，能够调用 BIOS；进入保护模式/long mode 后不再直接依赖实模式 BIOS 服务。
- 第 21 课已经证明 stage 1 会加载并执行 `stage2.bin`，stage 2 返回后旧启动路径继续工作。
- `ES:DI` 可以指向 BIOS 写入的内存缓冲区，物理地址仍按 `segment × 16 + offset` 计算。
- System V x86-64 ABI 使用 `RDI` 传递第一个参数；写 `EDI` 会把 `RDI` 高 32 位清零。
- C 结构体的字段 offset 必须与汇编写入的 byte layout 完全一致。

本课的 E820 循环、C 结构体、参数传递和检查器都由脚手架提供。你不需要从空白开始抄 BIOS 寄存器协议，只完成一个明确的“发布数量”操作。

参考资料：

- [Linux/x86 Boot Protocol](https://docs.kernel.org/arch/x86/boot.html)：成熟内核如何定义 bootloader → kernel 参数合同。
- [Linux x86 Zero Page](https://docs.kernel.org/arch/x86/zero-page.html)：Linux boot parameters 中 E820 table 的位置与角色。
- [Linux `arch/x86/kernel/setup.c`](https://github.com/torvalds/linux/blob/master/arch/x86/kernel/setup.c)：内核如何继续保留自身占用范围并处理 E820 RAM。

## 本课只引入一个机制

stage 2 通过 BIOS `INT 15h, EAX=E820h` 收集物理地址范围，写入固定格式的 `boot_info`；进入 long mode 后，stage 1 用 `RDI=0x5000` 把这份结构传给 C。

```text
BIOS E820
    │  writes entries through ES:DI
    ▼
0x5000 boot_info header
0x5020 E820 entry array
    │
    │ stage 2 RET → stage 1 enters long mode
    ▼
EDI = 0x5000 → RDI = 0x0000000000005000
    │
    ▼
kernel_main(const struct boot_info *info)
```

这里还不实现页分配器。目标是先让 producer（stage 2）和 consumer（C kernel）对同一批 bytes 达成可信合同。

## 开始前先认清五个角色

本课同时出现 BIOS、stage 2、C 和检查器。如果不先区分角色，很容易把“某地址出现一个值”误认为 E820 自带的行为。

| 名称 | 本课中是谁 | 做什么 |
|---|---|---|
| firmware / 固件 | QEMU 中的 SeaBIOS | 回答 E820 查询，把一项物理地址范围写到 `ES:DI` |
| producer / 生产者 | 我们的 stage 2 | 反复调用 E820，把 firmware entries 包装成 `boot_info` |
| handoff / 交接 | stage 1 的 `RDI=0x5000` | 跨过模式切换，把结构地址作为 C 第一个参数传递 |
| consumer / 消费者 | `kernel_main` 中的 C 代码 | 校验 header，再按 count 遍历 entries |
| checker / 观察者 | host 上的 `check-e820-boot-info.zsh` | 启动 QEMU，从外部读取 guest RAM，判断整条链路是否成立 |

完整数据流是：

```text
SeaBIOS
  │ 写一项原始 E820 entry
  ▼
stage 2
  │ 收集 entries，并发布自定义 boot_info header
  ▼
stage 1 / long-mode entry
  │ 只传递 RDI=0x5000，不重新解释内容
  ▼
C kernel
  │ 校验并遍历成功后，写一份课程测试回执
  ▼
0x7010 = "E820COK!"
  │
  ▼
host checker 读取并断言
```

这里的 `boot_info` **不是 BIOS E820 标准结构**，是我们为 bootloader → kernel 自己定义的 API（双方约定的数据接口）。BIOS 只知道单个 E820 entry，不知道 `BINF` magic、capacity、`RDI` 或 `E820COK!`。SysV ABI 只规定第一个 C 参数放在 `RDI`；它也不规定 `boot_info` 内部有哪些字段。

### acknowledgement 到底是什么

`acknowledgement` 常缩写为 `ack`，中文可理解为“确认回执”：接收方处理完一份输入后，留下一个发送方或测试者可以观察的成功信号。

本课的 C acknowledgement 有非常具体的定义：

- **谁写**：64 位 C 函数 `acknowledge_boot_info()`。
- **写到哪里**：guest physical/linear `0x7010..0x7017`。
- **写什么**：八个 ASCII bytes `E820COK!`。
- **何时写**：header 全部合法，并且 entries 中至少有一个 `type=1`、length 非零的范围。
- **谁读**：host 上的 QEMU 检查脚本，不是 BIOS，也不是已经返回的 stage 2。
- **是不是标准**：不是 E820、SysV ABI 或 Limine 的字段，只是课程测试用的机器证据。

它类似第 21 课的 `STAGE2OK`，但证明的阶段不同：

| marker | writer | 证明什么 |
|---|---|---|
| `STAGE2OK` at `0x7000` | 16-bit stage 2 | CPU 确实执行过 stage 2 入口 |
| `E820COK!` at `0x7010` | 64-bit C kernel | C 收到、校验并消费了非空 `boot_info` |

之所以不用再向 debug console 追加字符，是为了让历史输出 `HelloPTLKCUR` 保持不变；检查器通过另一块 RAM 观察新行为。它能证明 handoff 链路成功，但**不能**证明所有 E820 ranges 都正确、页已经对齐，或物理页分配器已经实现。

## 1. 为什么不能把“128 MiB”直接当作全部可用 RAM

QEMU 的 `-m 128M` 表示虚拟机配置了多少内存，不代表物理地址 `0..128 MiB` 每个字节都能交给分配器。PC 物理地址空间包含传统低内存洞、BIOS/ACPI 保留区、设备映射和其他不能随意覆盖的范围。

例如，一张简化 map 可能是：

```text
[0x00000000, 0x0009fc00)  usable
[0x0009fc00, 0x00100000)  reserved / firmware holes
[0x00100000, 0x07fe0000)  usable
[0x07fe0000, 0x08000000)  reserved
```

边界和条目数量由固件决定，不能根据内存总量猜。bootloader 的职责是把固件描述原样交给内核；哪些页最终加入 allocator 是后续 OS 策略。

常见 E820 type：

| type | 大意 | 当前是否直接视为可用 |
|---:|---|---|
| 1 | usable RAM | 后续可作为候选 |
| 2 | reserved | 否 |
| 3 | ACPI reclaimable | 当前否，使用完相关数据后才可能回收 |
| 4 | ACPI NVS | 否 |
| 5 | bad memory | 否 |

本课 C 端只要求 map 中存在至少一个 `type=1` 且 length 非零的 entry，证明数据不是空壳；真正按页对齐和排除内核自身占用范围留到物理页分配阶段。

## 2. E820 一次调用的寄存器合同

每次调用前，stage 2 设置：

```text
EAX = 0x0000e820      功能号
EDX = 0x534d4150      ASCII "SMAP" signature
ECX = 24              请求 24-byte entry
ES:DI                  BIOS 写入 entry 的目标缓冲区
EBX                     continuation token；第一次必须为 0
```

返回后检查：

```text
CF = 0                 调用成功
EAX = 0x534d4150       BIOS 回显 "SMAP"
ECX >= 20              至少包含 base/length/type
EBX                     下一次 continuation token；0 表示这是最后一项
```

一个 24-byte entry 与 C 定义一致：

```c
struct e820_entry {
    uint64_t base;        // offset 0
    uint64_t length;      // offset 8
    uint32_t type;        // offset 16
    uint32_t attributes;  // offset 20
};
```

前 20 bytes（base、length、type）是本课必须使用的核心字段；最后 4 bytes 是扩展 attributes。stage 2 在调用前把 attributes 预置为 1，并接受 BIOS 返回 `ECX>=20`。本课还不根据 attributes 制定分配策略，只保证 20-byte 固件也不会让核心字段缺失。

`SMAP` signature 是接口握手：stage 2 在 `EDX` 提交它，成功返回时再检查 `EAX` 是否回显同一数值，用来避免把不支持该功能或异常的 BIOS 返回误当作 memory entry。它与 `BINF` 不同：`SMAP` 属于 E820 调用合同，`BINF` 属于我们自定义的 boot_info 合同。

循环从 `EBX=0` 开始。每得到一个非零 length entry，就把内部计数 `BP` 加一、让 `DI` 前进 24 bytes；若 BIOS 返回 `EBX=0` 或容量达到 32，循环结束。

这里的 `EBX` 不是 entry count，也不是内存地址。它是 BIOS 拥有的 opaque continuation token（不透明续查令牌）：stage 2 只负责第一次传 0，之后把 BIOS 上次返回的值原样送回去，不能自行 `INC EBX` 猜下一项。

```text
第一次：stage 2 给 EBX=0     → BIOS 返回 entry 0 和 token A
第二次：stage 2 给 EBX=A     → BIOS 返回 entry 1 和 token B
...
最后：  BIOS 返回某项和 EBX=0 → 当前项仍有效，处理完后结束
```

因此循环中有三个容易混淆的状态：

- `EBX`：firmware 的“下一页游标”，只控制是否继续问 BIOS。
- `BP`：stage 2 接纳了多少个非零 length entries。
- `DI`：下一项应该写入 RAM 的 byte address；每接纳一项才增加 24。

当 BIOS 返回 zero-length entry 时，本课不增加 `BP/DI`，下次调用会覆盖同一个 slot；`EBX` 仍使用 BIOS 返回的新 token 继续。

对应的伪代码是：

```text
token = 0
count = 0
destination = 0x5020
do {
    entry, token = BIOS_E820(token, destination)
    validate CF / "SMAP" / returned size
    if entry.length != 0 {
        count++
        destination += 24
    }
} while token != 0 && count < 32
```

## 3. 为什么要有 `boot_info` header

只把 entry bytes 塞在某个约定地址还不够。C 必须知道：这是不是自己认识的协议版本、每项多大、有几项、最多能有几项，以及数组在哪里。

本课定义固定 32-byte header：

| physical | offset | C field | size | value |
|---:|---:|---|---:|---:|
| `0x5000` | 0 | `magic` | 4 | `0x464e4942`，bytes `BINF` |
| `0x5004` | 4 | `version` | 2 | 1 |
| `0x5006` | 6 | `entry_size` | 2 | 24 |
| `0x5008` | 8 | `entry_count` | 4 | 实际非空 entry 数 |
| `0x500c` | 12 | `entry_capacity` | 4 | 32 |
| `0x5010` | 16 | `entries_phys` | 8 | `0x5020` |
| `0x5018` | 24 | `reserved` | 8 | 0 |

entry array 从 `0x5020` 开始，容量是 `32 × 24 = 768 = 0x300` bytes，因此最后一个可能的字节是 `0x531f`。它不会与 `0x7000` 的 stage 2 handshake、`0x7010` 的 C acknowledgement、`0x7c00` 的 boot sector 或 `0x8000` 的 stage 2 冲突。

汇编按 offset 写字段，C 使用 `_Static_assert` 检查 `sizeof` 和关键 offset。两边任何一方改变 layout 而未同步，都会在构建或运行检查中暴露。

再次强调：`BINF` magic、version 和这个字段顺序都是**课程自定义 boot protocol**。magic 的作用不是加密或防止恶意输入，只是让 C 在解引用前发现“传进来的指针并不指向我认识的结构”。version 允许未来扩展格式，`entry_size` 防止 producer/consumer 对数组步长理解不同。

本课首次出现的 C layout 工具有：

| C 写法 | 作用 |
|---|---|
| `uint32_t` / `uint64_t` | 明确字段位宽，避免宿主平台的 `long` 大小差异 |
| `sizeof(struct e820_entry)` | 让 C 编译器报告自己认为每项占多少 bytes |
| `offsetof(struct boot_info, entry_count)` | 让编译器计算字段相对结构起点的 byte offset |
| `_Static_assert(condition, message)` | condition 不成立时直接让构建失败，不等到 guest 随机读错字段 |

`kernel/boot_info.h` 断言 entry 是 24 bytes、header 是 32 bytes、count offset 是 8、entries pointer offset 是 16。它们不是需要背诵的 C 花招，而是把汇编/C 共享 layout 变成构建期合同。

## 4. 这份结构如何跨过模式切换

stage 2 收集 E820 后 `RET` 回 stage 1。物理 bytes 留在 RAM，不会因为 CPU 从实模式进入 long mode 而消失。当前低 2 MiB 恒等映射还保证：long mode 中的虚拟地址 `0x5000` 仍指向物理 `0x5000`。

64 位入口新增：

```asm
mov edi, 0x5000
mov rax, KERNEL_LOAD_ADDR
jmp rax
```

写 `EDI` 会自动清零 `RDI` 高 32 位，所以 kernel 入口得到：

```text
RDI = 0x0000000000005000
```

`kernel_call_stub` 在调用 `kernel_main` 前不修改 `RDI`，于是 C 声明可以直接接收：

```c
void kernel_main(const struct boot_info *boot_info);
```

C 会验证 magic/version/entry size/count/capacity/pointer，并寻找至少一个非空 usable entry。全部成立后，它在 `0x7010` 写入 bytes `E820COK!`：

```text
45 38 32 30 43 4f 4b 21
```

QEMU monitor 作为 little-endian qword 显示为：

```text
0x214b4f4330323845
```

这份 acknowledgement 同时证明：stage 2 发布了 header、参数经过模式切换抵达 C、C 能按同一 layout 读取 entries。

### C consumer 实际做了什么

正文对应的 C 逻辑可以压缩为：

```c
static void acknowledge_boot_info(const struct boot_info *info) {
    if (info == 0
        || info->magic != BOOT_INFO_MAGIC
        || info->version != BOOT_INFO_VERSION
        || info->entry_size != sizeof(struct e820_entry)
        || info->entry_count == 0
        || info->entry_count > info->entry_capacity
        || info->entry_capacity > BOOT_INFO_MAX_ENTRIES
        || info->entries_phys != BOOT_INFO_ENTRIES_ADDR) {
        return;                         // 合同无效：不写成功回执
    }

    const struct e820_entry *entries =
        (const struct e820_entry *)(uintptr_t)info->entries_phys;

    for (uint32_t i = 0; i < info->entry_count; i++) {
        if (entries[i].type == E820_TYPE_USABLE && entries[i].length != 0) {
            *(volatile uint64_t *)(uintptr_t)BOOT_INFO_ACK_ADDR =
                BOOT_INFO_ACK_VALUE;   // 写 "E820COK!"
            return;
        }
    }
}
```

逐层看，它没有“相信并直接使用” stage 2 的数据：

1. 先验证固定 header，尤其是 `count <= capacity <= 32`，防止循环越过 buffer。
2. 把 header 中的整数物理地址 `entries_phys` 转成 C pointer。
3. 只遍历公开的 `entry_count` 项。
4. 至少找到一个非空 usable entry 后才写测试回执。

这里的两个新 C 写法：

- `uintptr_t` 是“能容纳指针数值的无符号整数类型”。先转成 `uintptr_t`，明确表示 `0x5020/0x7010` 是地址数值，再转成 pointer。
- `volatile uint64_t *` 告诉编译器这次内存写入是外部可观察行为，不能因为内核自己不再读取 `0x7010` 就把 store 优化掉。`volatile` 不提供锁、原子性或安全校验；这里只用于保留测试证据。

### acknowledgement 能证明与不能证明什么

`E820COK!` 出现可以推出：

```text
stage 2 至少发布了一个 entry
→ stage 1 把 0x5000 放进 RDI
→ C 按相同 layout 读到合法 header
→ C 在公开范围内找到至少一个 usable entry
→ C 的 store 真正执行
```

它不能推出：

```text
所有固件 entries 都无重叠且排序正确
所有 usable bytes 都能立刻分配
kernel/page tables/loader 占用范围已经扣除
页对齐、free list 或 allocator 已经建立
```

所以 acknowledgement 是“这一课的数据通路绿灯”，不是操作系统内存管理完成标志。

## 5. 红灯机制（先不要运行）

E820 循环已经能执行。它使用 `BP` 记录内部条目数，并把 entries 写到 `0x5020` 起始的 buffer；但结束处故意没有把 `BP` 发布到 header：

```asm
.e820_done:
    ; RED / TODO (lesson 22): publish BP into boot_info.entry_count.

    pop es
    ; ... restore and RET
```

header 初始化时已经把完整 32-bit `entry_count` 清零：

```asm
mov dword [BOOT_INFO_ADDR + 8], 0
```

因此红灯中会同时成立：

```text
0x5020 后面已有 BIOS 返回的非空 entry bytes
内部 BP 已经统计条目
boot_info.entry_count 仍为 0
C 按合同拒绝 count=0
0x7010 acknowledgement 仍为 0
旧输出仍为 HelloPTLKCUR
```

这是一盏“数据已收集、metadata 未发布”的干净红灯。这里的 metadata 是“描述 entries 的数据”，具体就是 count、size、capacity 和 pointer；它不是 E820 range 本身。红灯不是 E820 调用失败。

## 实验前预测

现在已经读完 E820 loop、header layout、ABI 路径和红灯成因。
在第一次运行 `make check-e820-boot-info` 前，把答案写入 `notes/05-C内核与Bootloader毕业/note-22.md`。

### 输入 A：header bytes

红灯在 `0x5000..0x5017` 写入：

```text
42 49 4e 46 01 00 18 00   00 00 00 00 20 00 00 00
20 50 00 00 00 00 00 00
```

### 输入 B：一组完全给出的合成 E820 返回

| call | length | returned EBX | 是否计数 |
|---:|---:|---:|---|
| 1 | `0x9fc00` | 1 | 是 |
| 2 | 0 | 2 | 否；下一项覆盖当前 slot |
| 3 | `0x7ee0000` | 0 | 是；随后结束 |

预测题：

1. 红灯时 monitor 把 `0x5000` 与 `0x5008` 各显示成什么 qword？说明低地址字节与显示顺序。
2. 对输入 B，循环结束时 `BP`、`DI` 分别是多少？若正确发布，`entry_count` 应是多少？
3. 红灯中第一个 entry length 已非零，但 `entry_count=0`。C 是否写 `E820COK!`？旧输出是否变化？分别说明原因。
4. 绿灯后 `0x7010..0x7017` 的 bytes 与 monitor qword 分别是什么？这份证据串起了哪三个执行阶段？
5. 为什么 `mov edi, 0x5000` 足以让 C 收到合法的 64-bit pointer？为什么不能只传 `0x5020` 而省略 header？

不要预测本机 QEMU 的精确 entry 数量；它属于实验后观察，固件变化时可以不同。错误预测原样保留。

## 6. 实验第一步：运行真实红灯

完成预测后运行：

```sh
make inspect-boot-info
make check-e820-boot-info
```

当前检查器应报告：

```text
E820 check: firmware entries exist at 0x5020, but stage 2 published entry_count=0
E820 check: publish the internal BP count at the lesson-22 TODO
E820 check: C acknowledgement remains 0x0000000000000000 at 0x7010
```

记录原始输出。检查器不会要求 count 等于某个固定数字，只要求 `0 < count <= capacity`，并验证 C acknowledgement。

## 7. 实验第二步：发布 entry count

打开 `boot/stage2.asm`，只完成 lesson 22 的单个 TODO：把内部 16-bit `BP` 写入 `boot_info.entry_count` 的低 16 位。

为什么本课这样写是安全的：

- header 已先把完整 32-bit field 清零，所以高 16 位保持 0。
- capacity 只有 32，实际 count 不可能超过 16-bit。
- `BOOT_INFO_ENTRY_COUNT` 已命名字段地址，不应再次写死 `0x5008`。

本课第一次需要的 NASM 形式是：

```asm
mov word [named_field_address], bp
```

不要修改 E820 loop、C 校验、capacity、acknowledgement 或检查器。

## 8. 绿灯与取证

完成后运行：

```sh
make inspect-boot-info
make check-e820-boot-info
make check-stage2-handoff
make check-exception
```

绿灯形式为：

```text
E820 check passed: stage 2 published N/32 entries and C consumed boot_info
E820 state: header=..., entries=0x5020, first_length=..., C_ack=..., output='HelloPTLKCUR'
```

`N` 是本次 firmware response，不是要背的标准答案。关键不变量是：

- header layout 正确；
- `0 < N <= 32`；
- 至少有一个非空 entry，C 能找到 usable range；
- `E820COK!` 由 C 写出；
- stage 2 handoff、异常路径和旧输出不变。

## 9. 简短的 OS 视角

`boot_info` 是 bootloader 与 kernel 之间的 API。magic/version/size/count 不是多余包装，它们让 consumer 能在解引用数组前验证 producer 的输入。后续页分配器只会接纳 `type=1` 的完整页，还必须排除 kernel、page tables、boot_info 和 loader 自身占用的范围。

## 观察题

1. 为什么 entries 已写入 RAM 仍不足以让 C 安全遍历？
2. `EBX` continuation token、内部 `BP` 和公开 `entry_count` 分别承担什么角色？
3. header 中为什么同时保存 `entry_size`、`entry_count` 和 `entry_capacity`？
4. 从 E820 BIOS 调用到 `E820COK!`，按顺序写出 producer → handoff → consumer 证据链。
5. 本课为什么只验证存在 usable range，还不能把它直接交给物理页分配器？

## 完成标准

- 五项预测在第一次运行红灯前完成；不猜本机的精确 entry 数量。
- 只修改 `boot/stage2.asm` 中 lesson 22 的单个 TODO。
- `make check-e820-boot-info` 证明非空 E820 map 经 `boot_info` 抵达 C。
- 能解释 E820 continuation、header layout、`RDI` 参数和 C acknowledgement。
- `make check-stage2-handoff` 与 `make check-exception` 继续通过。
- 能说明 E820 map 是候选物理范围描述，不等于已经实现 allocator。
