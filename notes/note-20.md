# 第 20 课学习记录

日期：2026.08.11

> 填写时机：先读完讲义第 1–5 节，理解产物大小、地址对应、扇区计数和红灯机制；然后在第一次运行 `make check-multisector-load` 前填写预测。

## 实验前预测

### 1. 红灯实际写入的 RAM 范围

- 字节数：512
- 起始物理地址：0x10000 
- 最后一个物理地址 0x101ff
- 计算过程：0x10000 + 1 * 512 - 1 = 0x101ff

### 2. 旧输出与尾部标记

- 是否仍输出 `HelloPTLKCUR`： 输出
- `0x107f8` 的预测状态： 未写入 0
- 两者为什么可以同时成立：因为现在 512 足够了，所以也没啥区别

### 3. 四扇区的最后一个字节

- `os.img` offset：0x7ff
- guest physical address：0x10000
- 计算过程：0x10000 + 4 * 512 - 1 = 0x107ff

### 4. 为什么旧异常检查不能证明完整加载

我的预测：因为没有检查尾部标记，所以不能证明完整加载。

### 5. CHS 连续读取范围

- 会读取的 sector：连续读 sector 2..5
- 为什么没有跨 track：当前 floppy 每条 track 有 18 个扇区，CHS sector 从 1 开始。读取从 CHS 0/0/2 开始的 4 个扇区，会覆盖 sector 2、3、4、5，没有跨过 track 边界：

## 红灯

### `make inspect-kernel-span`

```text
== kernel image size and last 16 bytes ==
    2048 build/kernel.bin
000007f0: 84 00 00 00 00 00 66 90 4c 4f 41 44 34 53 45 43  ......f.LOAD4SEC
== same tail bytes inside os.img ==
000009f0: 84 00 00 00 00 00 66 90 4c 4f 41 44 34 53 45 43  ......f.LOAD4SEC
```

### `make check-multisector-load`

```text
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
multi-sector check: the kernel starts correctly, but its last sector was not loaded
multi-sector check: expected tail 0x4345533444414f4c at physical 0x107f8
multi-sector check: load all KERNEL_SECTORS in boot/boot.asm
multi-sector check: actual tail 0x0000000000000000
make: *** [check-multisector-load] Error 1
```

文件里有尾部标记、RAM 中却没有，说明：没有读取到最后一个扇区。

## 我的实现

`boot/boot.asm` 中修改的一行：

```asm
    mov al, KERNEL_SECTORS
```

## 绿灯原始观察

### `make check-multisector-load`

```text
$ make check-multisector-load
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
multi-sector check passed: 4 sectors loaded at physical 0x10000..0x107ff
multi-sector state: tail 0x4345533444414f4c is present at 0x107f8, output='HelloPTLKCUR'
```

### 三项回归

```text
$ make check-image
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......

$ make check-kernel-elf
kernel ELF check passed: assembly and C objects linked at 0x10000, raw payload=2048 bytes
0000000000000800 A KERNEL_IMAGE_BYTES
0000000000010000 T kernel_start
0000000000010002 T kernel_magic
000000000001000a T kernel_entry
000000000001000e T kernel_hang
0000000000010010 t kernel_call_stub
000000000001001b T debug_putc
0000000000010020 T load_lesson_idt
0000000000010028 T trigger_invalid_opcode
000000000001002b T isr_invalid_opcode
000000000001006e T exception_red_hang
0000000000010070 T kernel_main
00000000000100a0 T idt_install
00000000000100e0 T invalid_opcode_handler
0000000000010100 T lesson_idt
0000000000010170 t lesson_idt_end
0000000000010170 t lesson_idtr

$ make check-exception
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, 4-sector kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 eb 04 90 90 eb fe  ..KERNEL64......
exception check passed: #UD -> vector 6 -> C handler -> IRETQ -> RIP=0x1000e
exception state: IDTR base=0x0000000000010100 limit=0x006f, output='HelloPTLKCUR'
```

## 我的解释

### 1. 为什么 2048 字节内核只加载 512 字节仍能暂时运行

我的解释：当前执行代码、IDT 和异常处理数据都位于第一个扇区；LOAD4SEC 位于第四个扇区，所以旧行为正常但加载合同仍不完整。

实验后坐标修正（保留上面的原始预测）：

```text
kernel.bin 最后一个 offset = 0x7ff
os.img offset             = 0x200 + 0x7ff = 0x9ff
guest physical            = 0x10000 + 0x7ff = 0x107ff
```

### 2. 构建大小与加载长度分别由谁负责

我的解释：构建大小由 linker 的 KERNEL_IMAGE_BYTES 决定；实际读取长度由 INT 13h 调用时的 AL 决定；check-multisector-load 检查两者最终一致。

### 3. 为什么必须检查尾部证据

我的解释：不检查不确定是不是读取的

### 4. 为什么固定 `AL=4` 仍不是最终方案

我的解释：因为可能还不止这么多扇区

### 5. bootloader 毕业边界

我的解释：
1. 多扇区载荷：磁盘长度与 RAM 中实际长度一致
2. 解除 512 字节代码空间和简单 CHS 的长期限制
3. 把真实物理内存布局传给 C
4. 内核栈和 ABI handoff
5. ELF PT_LOAD、.bss 清零，以及毕业复盘后才切换 Limine。

## 仍然不清楚的问题

- 
