# 第 7 课学习记录

日期：2026.08.08

## 实验前计算

1. `ffff:0010` 的线性地址：  0x100000
2. A20 关闭时该地址实际落到： 0x000000
3. `0xfe` 的 8 位二进制： 11111110
4. `0x02` 的 8 位二进制：00000010
5. 端口 `0x92` 的 bit 1 和 bit 0 分别控制：A20 enable 和  fast reset

## 红灯

- `make check-a20`： A20 check: expected A20=1 after boot code, got A20=0
- 红灯时 QEMU 报告的 A20： 0
- `Hello` 是否仍正常输出： 是，因为相关地址都低于 1 MiB，因为没用到 A20 1MB 之外的地址
- 为什么这证明测试读取的不是复位初始状态：测试等待 Hello，确认端口写入已经执行完毕，才读取 A20

## 我的实现

```asm
; 记录 A20 的读—改—写序列
in al, 0x92
and al, 0xfe
or al, 0x02
out 0x92, al
```

## 绿灯原始观察

- `make check-a20`：A20 check passed: QEMU reports A20=1 after boot code
- debug console 输出： debug console check passed: received 'Hello' from I/O port 0xe9
- 第一次进入 `putc` 时的 `SP` 0x7bfe
- 第一次进入 `putc` 时的返回地址：0x7c24
- A20 四条指令的机器码： E4 92 24 FE 0C 02 E6 92

## 我的解释

1. A20 关闭时为什么发生 1 MiB 回绕：因为早期的机器不支持，超过 20位就回到原位了
2. `and al, 0xfe` 的作用： bit 0 不是普通标志位，而是 fast reset；写成 1 可能让 CPU 复位
3. `or al, 0x02` 的作用： 只把 bit 1 置一，打开 A20
4. 为什么使用读—改—写而不是覆盖整个端口：因为端口中的其他位可能包含我们不应破坏的状态。
5. 为什么必须保护 bit 0：bit 0 是 fast reset；置 1 可能导致 CPU 复位。
6. 为什么不能依赖 BIOS 留下的 A20 状态： 不可靠性
7. 为什么低内存中的 `Hello` 不受影响： 因为没有超过 A20 的内存限制
8. A20 与实模式分段的区别：
	分段：segment × 16 + offset，形成线性地址
	A20 随后决定物理地址的 bit 20 是否被强制清零。

## 仍然不清楚的问题

-
