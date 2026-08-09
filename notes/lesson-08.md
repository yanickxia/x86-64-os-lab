# 第 8 课学习记录

日期：

## 实验前计算

1. `gdt` 地址：0x7c50
2. `gdt_end` 地址：0x7c68
3. `gdt_descriptor` 地址： 0x7c68
4. 三项 GDT 的总字节数：24
5. GDTR.limit：0x17
6. 伪描述符的六个内存字节： 17 00 50 7c 00 00

## 红灯

- `make inspect-gdt`：
	```
	$ make inspect-gdt
	00000050: 00 00 00 00 00 00 00 00 ff ff 00 00 00 9a cf 00  ................
	00000060: ff ff 00 00 00 92 cf 00 17 00 50 7c 00 00        ..........P|..
	```
- `make check-gdt`：
	```
	boot sector check passed: 512 bytes, signature 55aa
	000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
	GDT check: expected GDTR base=0x00007c50 limit=0x0017 after boot code
	GDT check: QEMU reported GDT=     00000000 00000000
	make: *** [check-gdt] Error 1
	```
- 红灯时 QEMU 报告的 GDT base 和 limit：base=0x00000000, limit=0x0000
- `Hello` 是否仍正常输出：Hello 实际正常输出。测试正是等待捕获到 Hello 后，才查询 GDTR；只不过成功捕获时没有把它打印出来。

## 我的实现

```asm
; 记录 LGDT 指令
lgdt [gdt_descriptor]
```

## 绿灯原始观察

- `make check-gdt`： GDT check passed: GDTR base=0x00007c50 limit=0x0017
- `LGDT` 的五个机器码字节： 0F0116687C
- 第一次进入 `putc` 时的 `SP`： 0x7bfe
- 第一次进入 `putc` 时的返回地址：0x7c29
- code descriptor 的八个内存字节： ff ff 00 00 00 9a cf 00
- data descriptor 的八个内存字节： ff ff 00 00 00 92 cf 00

## 我的解释

1. GDTR.limit 为什么是 size - 1：limit 使用“最后一个有效字节的偏移”，所以必须减一
2. `dq` 与 `lgdt` 的区别： dq：NASM 伪指令，汇编时生成8字节数据，CPU 不执行它。 LGDT：CPU 指令，运行时读取6字节伪描述符并修改 GDTR。
3. 小端序如何影响 descriptor 的内存字节顺序：多字节数值的最低有效字节存放在最低地址。
例如 0x00cf9a000000ffff 在内存中是：
ff ff 00 00 00 9a cf 00。
descriptor 各字段的位置由硬件格式另外规定。
4. code descriptor 中的 access byte 和 flags byte：access byte = 0x9a，flags/limit-high byte = 0xcf
5. `0x9a` 与 `0x92` 的关键差异：present、ring 0、data、writable 和 present、ring 0、code、executable、readable 的区别
6. selector `0x08`、`0x10` 如何对应 GDT 索引：
	0x08 >> 3 = 1 → GDT 第1项 code descriptor
	0x10 >> 3 = 2 → GDT 第2项 data descriptor
7. `LGDT` 为什么没有切换保护模式：lgdt 和保护模式是2个不同的东西，lgdt 是加载 GDT，保护模式是切换到保护模式，LGDT 只加载 GDTR。此时 CR0.PE 仍是 0，所以 CPU 仍在实模式。
8. `lgdt [gdt_descriptor]` 中方括号的意义：从 gdt_descriptor 指向的内存中读取 limit 和 base，再写入 GDTR。标签本身只是地址

## 仍然不清楚的问题

-
