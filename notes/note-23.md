# 第 23 课学习记录

日期：2026.08.11

> 先读讲义第 0–8 节，再填写下面三组预测。第一次运行 `make inspect-elf-loader` 或 `make check-elf-loader` 前完成；错误预测不要覆盖，实验后另写修正。

## 实验前预测

### 1. 两个 `PT_LOAD` 对应的内存动作

- LOAD 0 source 起点：0x20000 + 0x1000
- LOAD 0 destination 区间：0x10000
- LOAD 0 zero length：0
- LOAD 1 copy length：0x1000
- LOAD 1 zero interval：0x1000
- LOAD 1 最后一个 zero byte： 0x10fff
- 计算过程：0x10000 + 0x1000 - 1

### 2. 当前红灯的可观察状态

- `lesson23_bss_probe` qword：
- `0x7018` acknowledgement qword：ELF64OK!
- debug output：ELF64OK!
- 为什么代码可能运行、C 回执却仍失败：不知道

### 3. 第 22 课 handoff 如何延续

- `boot_info.kernel_entry_phys` 的地址：0x5000 + 0x18 =  0x5018
- `CALL kernel_main` 前的 `RSP` 及 `% 16`：0x15000, 0
- C 入口的 `RSP` 及 `% 16`： 0x10000， 0
- raw LBA 1..4 被清零后，kernel bytes 来自： 通过 ELF 读取的
- `JMP RAX` 的目标来自：从 ELF 得到的 kernel entry

## 静态观察

### `make inspect-elf-loader`

```text
== ELF program headers consumed by stage 2 ==

Elf file type is EXEC (Executable file)
Entry point 0x10000
There are 2 program headers, starting at offset 64

Program Headers:
  Type           Offset   VirtAddr           PhysAddr           FileSiz  MemSiz   Flg Align
  LOAD           0x001000 0x0000000000010000 0x0000000000010000 0x000800 0x000800 RWE 0x1000
  LOAD           0x001000 0x0000000000011000 0x0000000000011000 0x000000 0x004008 RW  0x1000

 Section to Segment mapping:
  Segment Sections...
   00     .text
   01     .bss
== ELF loader copy/poison/zero path ==
37:00008089  66C7061870000000  mov dword [0x7018],0x0
75:000080FB  C3                ret
155:00008211  F3A4              rep movsb
159:0000821D  B0A5              mov al,0xa5
160:0000821F  F3AA              rep stosb
173:00008237  C3                ret
177:0000823D  C3                ret
== .bss and dedicated stack symbols ==
0000000000011000 B __bss_start
0000000000011000 B kernel_stack_bottom
0000000000015000 B kernel_stack_top
0000000000015000 B lesson23_bss_probe
0000000000015008 B __bss_end
```

我把两个 program headers 翻译成的加载动作：

- LOAD 0：0x21000 → [0x10000,0x10800)，复制 0x800，不清零。
- LOAD 1：不复制，清零 [0x11000,0x15008)。

## 红灯

### `make check-elf-loader`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
ELF loader check: PT_LOAD file bytes reached C, but the NOBITS probe is 0xa5a5a5a5a5a5a5a5
ELF loader check: zero exactly p_memsz - p_filesz bytes at the lesson-23 TODO
ELF loader check: C environment acknowledgement remains 0x0000000000000000 at 0x7018
make: *** [check-elf-loader] Error 1
```

为什么它同时证明“ELF 代码已加载”和“`.bss` 合同未成立”：

- 当时范围被填成 0xA5，但没有被清零；代码段已成功复制，所以 kernel 能运行，C 因 probe 非零而不写回执。

## 我的实现

`boot/stage2.asm` 中新增的一行：

```asm
    rep stosb
```

## 绿灯原始观察

### `make check-elf-loader`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
ELF loader check passed: corrupted raw LBA 1 was ignored; stage 2 loaded 2048 file bytes from PT_LOAD
ELF state: entry=0x0000000000010000, bss_probe=0x0000000000000000, stack=0x0000000000011000..0x0000000000015000, RSP=0x0000000000015000, C_ack=0x214b4f3436464c45
```

### 三项旧回归

```text
$ make check-e820-boot-info

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
E820 check passed: stage 2 published 7/32 entries and C consumed boot_info
E820 state: header=0x00180001464e4942, entries=0x5020, first_length=0x000000000009fc00, C_ack=0x214b4f4330323845, output='HelloPTLKCUR'

$ make check-multisector-load

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
multi-sector check passed: 4 sectors loaded at physical 0x10000..0x107ff
multi-sector state: tail 0x4345533444414f4c is present at 0x107f8, output='HelloPTLKCUR'

$ make check-exception

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
disk image check: 6424-byte ELF image is present at LBA 18
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x00000000000101e0 limit=0x006f, output='HelloPTLKCUR'
```

## 我的解释

### 1. 从第 20–22 课到本课的职责迁移

我的解释：
- 第 20 课的 raw loader 只会把固定数量的 file bytes 搬到固定地址。
- 第 21 课建立 stage 2 的加载、执行与返回边界，但 kernel 仍由 stage 1 加载。
- 第 22 课把 E820 查询和 `boot_info` 生产职责迁入 stage 2。
- 第 23 课继续迁移 kernel loader：stage 2 消费 ELF `PT_LOAD`，发布 `e_entry`，stage 1 只负责后续模式切换和跳转。

### 2. `p_filesz`、`p_memsz` 与 `.bss`

我的解释：
- `p_offset` 是这段 file bytes 在 ELF 文件中的起点，`p_paddr` 是 loader 应建立的物理地址。
- `p_filesz` 是文件实际携带的长度；loader 先复制这部分。
- `p_memsz` 是运行时总长度；loader 再把 `p_memsz - p_filesz` 的尾部清零。
- `.bss` 是存放未显式初始化的静态存储期对象的 section。本课 linker 把它放进第二个 `PT_LOAD`：`p_filesz=0`、`p_memsz=0x4008`，所以文件不携带这批零，但 loader 必须在 RAM 中建立它们。

### 3. 专用内核栈与 ABI

我的解释：kernel 入口先把 `RSP` 切到 `kernel_stack_top=0x15000`。`CALL` 前 `RSP=0x15000`、对 16 余 0；CPU 压入 8-byte return address 后，C 入口 `RSP=0x14ff8`、对 16 余 8。设置 `RSP` 不修改 `RDI`，所以第 22 课的 `RDI=0x5000` 参数继续传给 `kernel_main`。

### 4. 从磁盘 ELF 到 C 回执的证据链

我的解释：临时镜像的 raw LBA 1..4 被破坏后，stage 2 仍把 LBA 18 的 ELF 读入 `0x20000` scratch；`PT_LOAD` 再把 file-backed bytes 复制到 `0x10000`、把 NOBITS 区间清零，并把 `e_entry` 写到 `0x5018`。stage 1 进入 long mode 后读取该 entry 跳转；kernel 切换到专用栈并调用 C，C 检查 probe 与局部变量地址后写出 `ELF64OK!`。这证明本课的数据通路成立，但不证明任意 ELF、stack guard、严格页权限或生产级磁盘错误恢复已经实现。

## 仍然不清楚的问题

- 暂无；第 24 课再把教学 loader 的已知限制整理为 bootloader 毕业边界。
