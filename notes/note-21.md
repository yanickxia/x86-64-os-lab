# 第 21 课学习记录

日期：2026.08.11

> 填写时机：先读完讲义第 1–5 节，理解 stage 分工、地址布局、加载/执行证据和红灯机制；然后在第一次运行 `make check-stage2-handoff` 前填写预测。

## 实验前预测

### 1. stage 2 的磁盘与 RAM 范围

原始预测（保留）：

- `os.img` 起止 offset：`0x0000..0xdff`
- guest physical 起止地址：stage2.bin `0x8000..0x83ff`，kernel.bin `0x10000..0x107ff`，boot.bin `0x7c00..0x7dff`
- `S2TAIL!!` 的 guest physical 起点：`0x83f8`
- 计算过程：`0x83ff - 7 = 0x83f8`

### 2. 红灯的三处内存证据

- `0x8000`：stage2.bin 被载入
- `0x83f8`： `S2TAIL!!` 被载入，读取完成了
- `0x7000`：stage 2 执行证据使用
- 各自能证明和不能证明什么：
  - `0x8000`：证明 stage2.bin 被载入
  - `0x83f8`：证明 `S2TAIL!!` 被载入，读取完成了
  - `0x7000`：证明 stage 2 执行证据使用
  - 不能证明什么其他的正常吧

### 3. `CALL/RET` 的栈状态

- stage 2 刚进入时的 `SP`：0x8000
- 栈顶地址和值：就是那个 stage1 的回归位置
- `RET` 后的 `IP/SP`：IP = 0x8000， SP=0x7bf4
- 计算依据：执行 lesson-21 调用前，SP=0x7bf4。
调用目标是 0x8000；入口的短跳转再到 0x8008。
stage2_entry 本身不额外压栈，最后执行 RET。

### 4. 执行握手的字节与 qword

- `0x7000..0x7007` 八个字节：STAGE2OK （53 54 41 47 45 32 4f 4b ）
- monitor qword：STAGE2OK
- little-endian 解释：逆序的

### 5. 红绿灯输出

实验前漏答（保留）：本题没有在第一次运行红灯前作答。

## 红灯

### `make inspect-stage2` / `make disassemble-stage2`

```text
== stage 2 source image: entry and tail ==
    1024 build/stage2.bin
00000000: eb 06 53 54 41 47 45 32 66 c7 06 00 70 53 54 41  ..STAGE2f...pSTA
00000010: 47 66 c7 06 04 70 45 32                          Gf...pE2
000003f0: 00 00 00 00 00 00 00 00 53 32 54 41 49 4c 21 21  ........S2TAIL!!
== same stage 2 bytes at os.img LBA 5 ==
00000a00: eb 06 53 54 41 47 45 32 66 c7 06 00 70 53 54 41  ..STAGE2f...pSTA
00000a10: 47 66 c7 06 04 70 45 32                          Gf...pE2
00000df0: 00 00 00 00 00 00 00 00 53 32 54 41 49 4c 21 21  ........S2TAIL!!
```

### `make check-stage2-handoff`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
stage2 check: stage 2 bytes are loaded at 0x8000, but its entry never executed
stage2 check: expected execution handshake 0x4b4f324547415453 at 0x7000
stage2 check: call STAGE2_LOAD_ADDR from the lesson-21 TODO in boot/boot.asm
stage2 check: actual handshake 0x0000000000000000
make: *** [check-stage2-handoff] Error 1
```

为什么这是“已加载、未执行”的干净红灯： 因为没有 IP 执行过

## 我的实现

`boot/boot.asm` 中替换三个 NOP 的一行：

```asm
call STAGE2_LOAD_ADDR
```

## 绿灯原始观察

### `make disassemble-boot`

只记录 lesson-21 调用点附近：

```text
00007D6B  E81100                            call 0x7d7f
00007D6E  E88F02                            call 0x8000
00007D71  EB00                              jmp 0x7d73
```

### `make check-stage2-handoff`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
stage2 check passed: stage 1 loaded and called stage 2, which returned to the historical boot path
stage2 state: image 0x8000..0x83ff, handshake 0x4b4f324547415453 at 0x7000, output='HelloPTLKCUR'
```

### 两项旧回归

```text
$ make check-multisector-load

boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
multi-sector check passed: 4 sectors loaded at physical 0x10000..0x107ff
multi-sector state: tail 0x4345533444414f4c is present at 0x107f8, output='HelloPTLKCUR'

$ make check-exception
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
disk image check: 2-sector stage 2 is present at LBA 5
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x0000000000010100 limit=0x006f, output='HelloPTLKCUR'
```

## 我的解释

### 1. 为什么 loaded 不等于 executed

我的解释：加载只表示 BIOS 把 `stage2.bin` 的字节复制到了 RAM；这个过程不会自动修改 `IP`。只有 `CALL 0x8000` 改变控制流，CPU 才会从这些字节取指并执行。因此 `0x8000` 有正确内容只能证明 loaded，`0x7000` 出现 stage 2 独有的副作用才能证明 executed。

实验后地址修正：

```text
stage2.bin offset = 0x000..0x3ff
os.img offset     = 0xa00..0xdff
guest physical    = 0x8000..0x83ff
S2TAIL!! physical = 0x83f8
```

红灯和绿灯都输出 `HelloPTLKCUR`：stage 2 不向 debug console 输出字符，并且绿灯执行完会 `RET` 回旧启动路径。因此只看输出不能证明 stage 2 执行，必须检查 `0x7000` 的独立握手。

### 2. 三个标记分别证明什么

我的解释：
- `STAGE2` 位于开头，证明 stage 2 的起始字节已加载；单独看它不能证明尾部完整或 CPU 执行过。
- `S2TAIL!!` 位于 offset `0x3f8`，与开头一起证明完整 1024 bytes 已加载；它仍不能证明 CPU 执行过。
- `STAGE2OK` 写在独立地址 `0x7000`，证明 CPU 到达并执行了 stage 2 入口。

执行后的内存和 monitor 观察是同一批字节的两种表示：

```text
0x7000..0x7007 bytes = 53 54 41 47 45 32 4f 4b  ("STAGE2OK")
monitor qword        = 0x4b4f324547415453
```

最低地址 `0x7000` 保存整数的最低有效字节 `0x53`；monitor 按 little-endian 组成 64-bit 整数后，把最高有效位显示在左侧。

### 3. `CALL/RET` 如何恢复旧路径

我的解释：

```text
CALL 前                 SP = 0x7bf4
CALL 压入返回 IP        [SS:0x7bf2] = 0x7d71
stage 2 刚进入          IP = 0x8000, SP = 0x7bf2
短跳转后执行入口         IP = 0x8008, SP = 0x7bf2
RET 后                  IP = 0x7d71, SP = 0x7bf4
```

`CALL` 先把下一条指令 `0x7d71` 压栈，再把 IP 改为 `0x8000`；stage 2 没有额外压栈，`RET` 取回同一个返回 IP，所以 stage 1 能从 `0x7d71` 继续旧路径。`0x8000` 是代码入口，不是栈指针。

### 4. 为什么现在可返回、最终通常不返回

我的解释：当前 A20、GDT、分页、long mode 和 kernel handoff 仍在 stage 1，所以 stage 2 写完握手后必须返回，让旧代码继续完成启动。最终这些职责迁入 stage 2 后，它会单向把控制权交给 kernel；stage 1 已经没有需要恢复的调用现场，因此最终 handoff 通常不返回。

### 5. 为什么 E820 应进入 stage 2

我的解释：E820 是 BIOS 实模式服务，必须在 BIOS 环境仍可用时查询；遍历 entries、检查签名和构造 `boot_info` 又会继续增加代码与数据。把它放进已加载且空间可扩展的 stage 2，可以让 512-byte stage 1 只承担最小加载与交接职责，并让 stage 2 把结构化内存图传给后续 C kernel。

## 仍然不清楚的问题

- 
