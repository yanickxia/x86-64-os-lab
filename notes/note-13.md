# 第 13 课学习记录

日期：2026.08.10

## 实验前预测

先读完讲义正文与红灯机制说明，再在第一次运行 `make check-kernel-entry` 前填写；错误预测原样保留。

1. 红灯的完整输出、最终 `RIP`，以及从四个 NOP 开始的取指路径：输出是 HelloPTL 最终的 RIP，应该是 0x7d35
2. 换成 `mov rax, KERNEL_LOAD_ADDR` / `jmp rax` 后，预测的取指地址序列、完整输出和最终 `RIP`： 输出 K，RIP是 0x10010
3. 跳转前后 `CS` 的 selector、解码模式及是否变化：不清楚
4. 两条实现指令各自的预测长度与总字节数：7 和 16 字节
5. 载荷输出 `K` 后的完整 `RAX`，以及两步推演过程： 不清楚 
6. 误跳 `0x1000a` 时，预测的输出、`RIP`、测试结果及原因：不清楚
7. 误跳 `0x10002` 时，CPU 如何看待 magic，以及预测的结果（正常输出／异常／错误字符）：不认识，应该会报错
8. “输出了 `K`”与“`RIP` 正停在载荷中”哪项证据更强，各自排除不了什么：RIP 更强，说明执行到了某个地址了

### 实验前预测复盘

保留上面的原始预测作为学习记录；实验后修正如下：

1. 红灯依次执行 `0x7d30 mov`、`0x7d32 out`、`0x7d34..0x7d37` 的四条 NOP，再到 `0x7d38` 的自跳转；完整输出是 `HelloPTL`，最终 `RIP=0x7d38`。
2. 绿灯从 `0x7d34` 的交接代码跳到 `0x10000`，随后取指 `0x10000 → 0x1000a → 0x1000c → 0x1000e`；完整输出是 `HelloPTLK`，最终 `RIP=0x1000e`。
3. `jmp rax` 是 near jump，只修改 `RIP`，不重新加载 `CS`，所以前后均为 selector `0x18`、`CS64`。
4. NASM 实际生成 5 字节的 `mov eax,0x10000` 和 2 字节的 `jmp rax`，合计 7 字节。
5. 装入目标后 `RAX=0x10000`；载荷执行 `mov al,'K'`，只把最低 8 位从 `0x00` 改成 `0x4b`，所以最终 `RAX=0x1004b`。
6. 误跳 `0x1000a` 会绕过载荷自己的入口短跳转，直接执行 `mov/out/hang`；输出、最终 `RIP` 和现有测试都可能与从 `0x10000` 进入完全相同。
7. CPU 不知道 `KERNEL64` 是数据；从 `0x10002` 进入时会把这些字节当作指令解码，可能产生错误字符、异常或其他非预期控制流，不能期待正常语义。
8. 输出 `K` 证明过去执行到载荷的 `OUT`；`RIP=0x1000e` 还证明采样时 CPU 当前位于载荷中，因此更强。但两者都不能排除最初直接跳到 `0x1000a`，不能单独证明入口一定是 `0x10000`。

## 红灯

- `make disassemble-kernel`：
  ```
  == payload entry jump at 0x10000 ==
  00010000  EB08                              jmp 0x1000a
  == KERNEL64 magic data at 0x10002-0x10009 (not instructions) ==
  00000002: 4b 45 52 4e 45 4c 36 34                          KERNEL64
  == payload code at 0x1000a-0x1000f ==
  0001000A  B04B                              mov al,0x4b
  0001000C  E6E9                              out byte 0xe9,al
  0001000E  EBFE                              jmp 0x1000e
  ```
- `make check-debugcon` 原始失败输出：
  ```
  debug console: expected 'HelloPTLK', got 'HelloPTL'
  ```
- `make check-kernel-entry` 原始失败输出：
  ```
  kernel-entry check: the payload never wrote its own character to port 0xe9
  kernel-entry check: expected debug output 'HelloPTLK', got 'HelloPTL'
  kernel-entry check: RIP is not parked in the payload hang loop
  kernel-entry check: expected RIP=000000000001000e (kernel/payload.asm .hang)
  kernel-entry check: actual RIP=0000000000007d38
  ```
- 红灯时 `RIP`：0000000000007d38
- 红灯时仍然通过的旧检查（逐个列出运行结果）：`make check-kernel-load`、`check-a20`、`check-gdt`、`check-protected`、`check-page-tables`、`check-long-mode` 全部通过。


## 我的实现

```asm
; 只记录 long_mode_entry 中由我补齐的代码
mov rax, KERNEL_LOAD_ADDR
jmp rax
```

## 绿灯原始观察

- `make check-kernel-entry` 完整输出：
  ```
  boot sector check passed: 512 bytes, signature 55aa
  000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
  disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
  00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
  kernel-entry check passed: payload executing at 0x1000e under CS=0x18 (CS64)
  ```
- `make check-debugcon` 输出：debug console check passed: received 'HelloPTLK' from I/O port 0xe9
- `make disassemble-boot` 中 `0x7d30` 区域的反汇编：
  ```
  00007D30  B04C                              mov al,0x4c
  00007D32  E6E9                              out byte 0xe9,al
  00007D34  B800000100                        mov eax,0x10000
  00007D39  FFE0                              jmp rax
  00007D3B  EBFE                              jmp 0x7d3b
  ```
- 绿灯时 `RIP`： 000000000001000e
- 绿灯时 `CS` 完整一行：CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
- 绿灯时 `RAX`： RAX=000000000001004b RBX=0000000000000000 RCX=00000000c0000080 RDX=0000000000000000
- 观察题 6 中 `jmp KERNEL_LOAD_ADDR` 的机器码：`00007D34 E9C7820000 jmp 0x10000`。opcode 是 `E9`；rel32 的小端字节为 `C7 82 00 00`，数值是 `0x82c7`。下一条地址 `0x7d39 + 0x82c7 = 0x10000`。`check-kernel-entry` 与 `check-debugcon` 仍然通过，记录后已恢复间接跳转实现。
- 旧课完整回归结果：
  ```
  $ make check-kernel-entry
    make check-debugcon
    make check-kernel-load
    make check-segments
    make check-call
    make check-a20
    make check-gdt
    make check-protected
    make check-page-tables
    make check-long-mode
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    kernel-entry check passed: payload executing at 0x1000e under CS=0x18 (CS64)
    QEMU 11.0.3 monitor - type 'help' for more information
    (qemu) info registers

    CPU#0
    RAX=000000000001004b RBX=0000000000000000 RCX=00000000c0000080 RDX=0000000000000000
    RSI=0000000000007c45 RDI=0000000000004000 RBP=0000000000000000 RSP=0000000000090000
    R8 =0000000000000000 R9 =0000000000000000 R10=0000000000000000 R11=0000000000000000
    R12=0000000000000000 R13=0000000000000000 R14=0000000000000000 R15=0000000000000000
    RIP=000000000001000e RFL=00000086 [--S--P-] CPL=0 II=0 A20=1 SMM=0 HLT=0
    ES =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
    CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
    SS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
    DS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
    FS =0000 0000000000000000 0000ffff 00009300 DPL=0 DS   [-WA]
    GS =0000 0000000000000000 0000ffff 00009300 DPL=0 DS   [-WA]
    LDT=0000 0000000000000000 0000ffff 00008200 DPL=0 LDT
    TR =0000 0000000000000000 0000ffff 00008b00 DPL=0 TSS64-busy
    GDT=     0000000000007c50 0000001f
    IDT=     0000000000000000 000003ff
    CR0=80000011 CR2=0000000000000000 CR3=0000000000001000 CR4=00000020
    DR0=0000000000000000 DR1=0000000000000000 DR2=0000000000000000 DR3=0000000000000000 
    DR6=00000000ffff0ff0 DR7=0000000000000400
    EFER=0000000000000500
    FCW=037f FSW=0000 [ST=0] FTW=00 MXCSR=00001f80
    FPR0=0000000000000000 0000 FPR1=0000000000000000 0000
    FPR2=0000000000000000 0000 FPR3=0000000000000000 0000
    FPR4=0000000000000000 0000 FPR5=0000000000000000 0000
    FPR6=0000000000000000 0000 FPR7=0000000000000000 0000
    XMM00=0000000000000000 0000000000000000 XMM01=0000000000000000 0000000000000000
    XMM02=0000000000000000 0000000000000000 XMM03=0000000000000000 0000000000000000
    XMM04=0000000000000000 0000000000000000 XMM05=0000000000000000 0000000000000000
    XMM06=0000000000000000 0000000000000000 XMM07=0000000000000000 0000000000000000
    XMM08=0000000000000000 0000000000000000 XMM09=0000000000000000 0000000000000000
    XMM10=0000000000000000 0000000000000000 XMM11=0000000000000000 0000000000000000
    XMM12=0000000000000000 0000000000000000 XMM13=0000000000000000 0000000000000000
    XMM14=0000000000000000 0000000000000000 XMM15=0000000000000000 0000000000000000
    (qemu) quit
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    qemu-system-x86_64: terminating on signal 15 from pid 37618 (<unknown process>)
    debug console check passed: received 'HelloPTLK' from I/O port 0xe9
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    kernel-load check passed: sector 2 is present at physical 0x10000
    QEMU 11.0.3 monitor - type 'help' for more information
    (qemu) xp /2gx 0x10000
    00010000: 0x4c454e52454b08eb 0xfeebe9e64bb03436
    (qemu) quit
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    warning: No executable has been specified and target does not support
    determining executable automatically.  Try using the "file" command.
    0x000000000000fff0 in ?? ()
    Hardware assisted breakpoint 1 at 0x7c10

    Breakpoint 1, 0x0000000000007c10 in ?? ()

    --- segment and stack state at main ---
    cs             0x0                 0
    ds             0x0                 0
    es             0x0                 0
    ss             0x0                 0
    sp             0x7c00              0x7c00
    eflags         0x246               [ IOPL=0 IF ZF PF ]
    segment/stack check passed: DS=ES=SS=0, SP=0x7c00 at main
    [Inferior 1 (process 1) detached]
    qemu-system-x86_64: terminating on signal 15 from pid 37788 (<unknown process>)
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    warning: No executable has been specified and target does not support
    determining executable automatically.  Try using the "file" command.
    0x000000000000fff0 in ?? ()
    Hardware assisted breakpoint 1 at 0x7c30
    Hardware assisted breakpoint 2 at 0x7c29

    Breakpoint 1, 0x0000000000007c30 in ?? ()

    --- putc entry: return address is on the stack ---
    cs             0x0                 0
    rip            0x7c30              0x7c30
    ss             0x0                 0
    sp             0x7bfe              0x7bfe
    ax             0x48                72
    stack linear address: 0x7bfe
    0x7bfe: 0x7c29

    Breakpoint 2, 0x0000000000007c29 in ?? ()

    --- after ret: execution resumes after call ---
    cs             0x0                 0
    rip            0x7c29              0x7c29
    ss             0x0                 0
    sp             0x7c00              0x7c00
    ax             0x48                72
    call/ret check passed: return=0x7c29, SP 0x7c00 -> 0x7bfe -> 0x7c00
    [Inferior 1 (process 1) detached]
    qemu-system-x86_64: terminating on signal 15 from pid 37896 (<unknown process>)
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    A20 check passed: QEMU reports A20=1 after boot code
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    GDT check passed: GDTR base=0x00007c50 limit=0x001f
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    protected-mode foundation check passed: CR0.PE=1, CS=0x0008/0x0018, DS=SS=0x0010
    protected-mode state: CR0=80000011 CR2=0000000000000000 CR3=0000000000001000 CR4=00000020
    protected-mode state: CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
    protected-mode state: DS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
    protected-mode state: SS =0010 0000000000000000 ffffffff 00cf9300 DPL=0 DS   [-WA]
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    page-table synchronization output: received 'HelloPTLK' from I/O port 0xe9
    page-table check passed: low 2 MiB identity map is present (Accessed bit may be set)
    page-table state: PML4[0]=00001000: 0x0000000000002023
    page-table state: PDPT[0]=00002000: 0x0000000000003023
    page-table state: PD[0]  =00003000: 0x00000000000000a3
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    long-mode check passed: CPU is executing 64-bit code
    long-mode state: CR0=80000011 CR2=0000000000000000 CR3=0000000000001000 CR4=00000020
    long-mode state: CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
    long-mode state: EFER=0000000000000500
  ```

## 我的解释

1. 载荷四条 CPU 指令的地址、magic 数据范围，以及 `EB 08` 的位移是怎么算出来的：
   ```
   0x10000  EB 08   jmp short kernel_entry
   短跳转的位移从下一条指令 0x10002 开始计算：0x10002 + 0x08 = 0x1000a
    0x10000  jmp kernel_entry
    0x10002  KERNEL64 数据，覆盖到 0x10009
    0x1000a  mov al,'K'
    0x1000c  out 0xe9,al
    0x1000e  jmp 0x1000e
    下一条地址 0x10010 - 2 = 0x1000e
   ```
2. 绿灯 `RIP` 是多少，为什么它比"输出了 `K`"更强：`RIP=0x1000e`。输出 `K` 只能证明 CPU 过去执行过载荷中的 `OUT`；monitor 捕获 `RIP=0x1000e` 还证明采样时 CPU 当前正停在载荷自己的循环中。
3. 绿灯 `CS` 完整一行，相比第 11 课有无变化，说明了什么：`CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]`，与第 11 课相同。`jmp rax` 是 near jump，只修改 `RIP`，不会重新加载 `CS`。
4. 我写的两条指令的机器码，`mov` 用了哪种编码，为什么可以这样选：`B8 00 00 01 00` 是 5 字节的 `mov eax,0x10000`，`FF E0` 是 2 字节的 `jmp rax`。虽然源码写 `rax`，但立即数能装入 32 位；64 位模式写 `EAX` 会自动清零 `RAX` 高 32 位，因此 NASM 可以选择更短且结果相同的编码。
5. `RAX=0x000000000001004b` 每一部分的来源：写 `EAX` 会清零 `RAX` 高 32 位，装入目标后 `RAX=0x0000000000010000`；载荷的 `mov al,'K'` 再把最低 8 位改成 ASCII `K` 的 `0x4b`。
   ```
    原值：0x0000000000010000
                              ^^ AL=00
    新值：0x000000000001004b
                              ^^ AL=4b
   ```
6. `jmp KERNEL_LOAD_ADDR` 的 opcode 与位移验算，测试是否通过，为什么仍不是本课要的写法：机器码是 `E9 C7 82 00 00`，opcode 为 `E9`，rel32 是 `0x82c7`；`0x7d39 + 0x82c7 = 0x10000`。测试仍然通过，说明当前相对写法本身正确；本课选择 `mov` 加间接 `jmp`，是为了显式观察绝对目标并提前练习未来高半区可能需要的间接形式。
7. `bits 64` 下写 `jmp 0x18:0x10000` 的结果与原因，64 位唯一可用的 far jump 形式：载荷也是 64 位代码，跟启动扇区共用同一个 code descriptor（selector `0x18`），`CS` 不需要变，所以 near jump 足够。直接 far jump 的 `EA ptr16:32` 形式在 64 位模式不受支持，NASM 会报错；64 位下需要 far jump 时只能使用从内存取得 selector 和 64 位 offset 的间接 `JMP m16:64`。
8. 为什么用 `jmp` 而不是 `call`，改成 `call` 缺哪几项约定：`call` 隐含载荷会返回，而返回需要双方约定谁拥有栈、哪些寄存器由被调用方保存、返回值放在哪里。当前还没有建立这些 ABI 约定，所以使用单向 `jmp`。

## 仍然不清楚的问题

-
