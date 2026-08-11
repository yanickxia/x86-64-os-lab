# 第 12 课学习记录

日期：2026.08.09

> 填写时机：先读完 BIOS 读盘正文和红灯机制说明，再在第一次运行 `make check-kernel-load` 前填写预测。

## 实验前预测

1. `ES=0x1000, BX=0` 对应的物理地址，以及载荷最后一个字节的地址：物理位置就是 `0x10000`， 最后一个是 0x101ff
2. 文件偏移 `0x200`、LBA 1、CHS 0/0/2 的关系： LBA 1 = 第 2 个扇区 = 文件偏移 1 × 512 = 0x200 ，
 ```
 镜像文件偏移 0x200
    = LBA 1
    = BIOS CHS cylinder 0 / head 0 / sector 2
 ```
3. 调用 BIOS 前 `AX/BX/CX/DX/ES` 的关键值：到 main 时 ES=0、SP=0x7c00，而后续代码也不应意外继承 BIOS 的临时返回值。
4. `DL` 的来源，以及为什么不能假定总是 `0x00`：DL 就是 DH 的低 8 位，高 8 位是 0 位，所以不能假定总是 `0x00`。
5. `CF=0/1` 的含义与失败条件跳转：CF=0 表示成功，CF=1 表示失败。
6. sector 2 的前 16 个字节与两个 little-endian qword：两个 qword 分别是 0x10000000 和 0x00000000。
7. 为什么在 `CR0.PE=1` 前读盘：读取的内存地址是物理地址，而不是虚拟地址。
8. 为什么 `HelloPTL` 不能证明载荷已读入：读取的内存地址是物理地址，而不是虚拟地址，所以不能证明载荷已读入。

### 实验前预测复盘

保留上面的原始预测作为学习记录；实验后修正如下：

1. `ES:BX=0x1000:0x0000` 对应物理地址 `0x10000`；512 字节载荷覆盖 `0x10000..0x101ff`。
2. raw image 的 LBA 从 0 开始，经典 BIOS CHS 的 sector 从 1 开始。因此文件偏移 `0x200 = 1 × 512` 是 LBA 1，也就是 CHS `0/0/2`。
3. 调用 `INT 13h` 前的关键值是 `AX=0x0201`、`BX=0x0000`、`CX=0x0002`、`DH=0`、`DL=BIOS 传入的启动驱动器号`、`ES=0x1000`。
4. `DL` 是 `DX` 的低 8 位，由 BIOS 在进入 boot sector 时提供，用来标识启动驱动器；它不一定总是 floppy 的 `0x00`。`DH` 是 `DX` 的高 8 位，本课用它指定 head 0。
5. 此 BIOS 服务返回 `CF=0` 表示成功，`CF=1` 表示失败；失败时用 `JC .disk_read_failed` 跳转。
6. sector 2 的前 16 字节是 `EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE`，显示为两个 little-endian qword 是 `0x4c454e52454b08eb` 和 `0xfeebe9e64bb03436`。
7. 传统 BIOS 磁盘服务依赖实模式 IVT、16 位执行环境和实模式段地址约定，因此应在设置 `CR0.PE`、进入保护模式之前调用。
8. `HelloPTL` 来自原有 boot sector 控制流；即使 `load_kernel` 直接返回，它仍会输出，所以不能证明 `0x10000` 已有载荷。

## 红灯

- `make inspect-image`：
  ```
  == boot signature and start of sector 2 ==
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
00000210: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................

  ```
- `make check-kernel-load` 原始失败输出：
```
boot sector check passed: 512 bytes, signature 55aa
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
kernel-load check: expected sector-2 payload at physical 0x10000
kernel-load check: expected qwords 0x4c454e52454b08eb and 0xfeebe9e64bb03436
kernel-load check: actual monitor output:
QEMU 11.0.3 monitor - type 'help' for more information
(qemu) xp /2gx 0x10000
00010000: 0x0000000000000000 0x0000000000000000
(qemu) quit
make: *** [check-kernel-load] Error 1
```
- 红灯时物理地址 `0x10000` 的两个 qword： 0x0000000000000000 和 0x0000000000000000
- 为什么这是本课机制缺失，而不是镜像构建失败：因为打印 disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1 说明是正常的

## 我的实现

```asm
; 只记录 load_kernel 中由我补齐的代码
mov ax, KERNEL_LOAD_SEGMENT
mov es, ax
mov bx, 0x0000

mov ah, 0x02
mov al, 0x01
mov ch, 0x00
mov cl, 0x02
mov dh, 0x00
int 0x13
jc .disk_read_failed
jmp .done
```

## 绿灯原始观察

- `make check-kernel-load` 完整输出：
  ```
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    disk image check passed: 1.44 MiB image, boot sector at LBA 0, kernel payload at LBA 1
    00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
    kernel-load check passed: sector 2 is present at physical 0x10000
    QEMU 11.0.3 monitor - type 'help' for more information
    (qemu) xp /2gx 0x10000
    00010000: 0x4c454e52454b08eb 0xfeebe9e64bb03436
    (qemu) quit
  ```
- `make disassemble-boot` 中 `load_kernel` 的反汇编：

  ```
  00007D50  50                                push ax
  00007D51  53                                push bx
  00007D52  51                                push cx
  00007D53  52                                push dx
  00007D54  06                                push es
  00007D55  B80010                            mov ax,0x1000
  00007D58  8EC0                              mov es,ax
  00007D5A  BB0000                            mov bx,0x0
  00007D5D  B402                              mov ah,0x2
  00007D5F  B001                              mov al,0x1
  00007D61  B500                              mov ch,0x0
  00007D63  B102                              mov cl,0x2
  00007D65  B600                              mov dh,0x0
  00007D67  CD13                              int byte 0x13
  00007D69  7208                              jc 0x7d73
  00007D6B  EB00                              jmp 0x7d6d
  00007D6D  07                                pop es
  00007D6E  5A                                pop dx
  00007D6F  59                                pop cx
  00007D70  5B                                pop bx
  00007D71  58                                pop ax
  00007D72  C3                                ret
  00007D73  B045                              mov al,0x45
  00007D75  E6E9                              out byte 0xe9,al
  00007D77  EBFA                              jmp 0x7d73
  ```

- `make inspect-image` 中 sector 1/2 边界：
```
== boot signature and start of sector 2 ==
000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
00000200: eb 08 4b 45 52 4e 45 4c 36 34 b0 4b e6 e9 eb fe  ..KERNEL64.K....
00000210: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................
```
- `make check-segments` 中 `ES` 与 `SP`：0x0 和 0x7c00
- 旧课完整回归结果：运行 `make check-tools check-boot check-debugcon check-segments check-call check-a20 check-gdt check-protected check-page-tables check-long-mode`，全部通过。

## 我的解释

1. `inspect-image` 如何证明两个扇区的边界：输出从文件偏移 `0x1f0` 开始展示 boot sector 的最后 16 字节，其中 `0x1fe..0x1ff` 是签名 `55 aa`；下一行从 `0x200` 开始，正好出现 payload 的 `EB 08 4B 45...`，因此同时展示了 sector 1 的末尾和 sector 2 的开头。
2. 两个 qword、内存字节顺序与 little-endian：两个 qword 是 `0x4c454e52454b08eb` 和 `0xfeebe9e64bb03436`。第一个数还原成从低到高地址排列的内存字节是 `EB 08 4B 45 52 4E 45 4C`；最低有效字节 `EB` 位于最低地址 `0x10000`。
3. `INT 13h`、`JC` 的机器码和跳转目标：`INT 13h` 在 `0x7d67`，机器码是 `CD 13`；`JC` 在 `0x7d69`，机器码是 `72 08`，目标地址是 `.disk_read_failed` 的 `0x7d73`。
4. `DH` 与 `DL` 为什么互不破坏：`DH` 是 `DX` 的 bit 15..8，本课保存 CHS head；`DL` 是 bit 7..0，保存 BIOS 传入的启动驱动器号。执行 `mov dh, 0` 只改写高 8 位，不会改变 `DL`。
5. 保存/恢复 `ES` 的作用，以及栈最多向下移动的字节数：`load_kernel` 临时令 `ES=0x1000` 作为 BIOS 缓冲区，返回前恢复原值，使 `main` 入口仍保持 `ES=0`。`CALL` 的 2 字节返回 IP 加上五次 16 位 `PUSH` 的 10 字节，共向下移动 12 字节：`0x7c00 → 0x7bfe → 0x7bf4`（不计 `INT` 和 BIOS 处理程序内部临时使用的栈）。
6. `CL=1` 会读到什么，以及测试大概会看到什么：`CL=1` 表示 CHS sector 1，会把 boot sector 而不是 payload 读到 `0x10000`；扇区数量由 `AL` 决定。测试会看到 bootloader 的开头指令字节，第一个 qword 会是 `0x8ed88ec08ec031fa`，而不是包含 `KERNEL64` 的期望值。
7. `ORG`、写镜像和读入 RAM 分别由谁完成：`ORG 0x10000` 由 NASM 处理，只影响标签和地址计算，不执行加载；Makefile 中的 `dd` 在宿主机上把 `kernel.bin` 写到镜像文件偏移 `0x200`；运行时 bootloader 通过 `INT 13h` 请求 BIOS 把该扇区读入 guest RAM `0x10000`。
8. 为什么把“读入”和“执行”拆成两课：本课只检查 `0x10000` 的 RAM 内容，能够独立证明磁盘读取正确；下一课再跳到载荷取指，并用新的控制流证据证明执行正确。这样失败时可以区分“没有正确加载”和“加载正确但跳转或执行失败”。

## 仍然不清楚的问题

-
