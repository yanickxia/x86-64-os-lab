# 第 6 课学习记录

日期：

## 实验前计算

1. `message` 地址：0x7c40
2. 七个数据字节： 48 65 6c 6c 6f 00 5a
3. 第一次读取时的 `DS:SI` 与线性地址：0x7c40
4. 读到 NUL 时的 `SI`： 0x7c45
5. 读到 NUL 后的 `ZF`： 1

## 红灯

- `make check-debugcon`： debug console: expected 'Hello', got 'X'
- `make inspect-message`： 00000040: 48 65 6c 6c 6f 00 5a                             Hello.Z
- 失败原因： 代码里面没有这个逻辑，只有 mov al, 'X' 然后 put io 了

## 我的实现

```asm
; 记录字符串循环

main:
    mov si, message

.loop:
    mov al, [si]
    test al, al
    jz hang
    call putc
    inc si
    jmp .loop

hang:
    jmp hang

```

## 绿灯原始观察

- debug console 输出：debug console check passed: received 'Hello' from I/O port 0xe9
- 第一次进入 putc 时的 `SP`： 0x7bfe
- 第一次进入 putc 时的返回地址： 0x7c1c
- `call` 机器码： E81400
- message 的七个字节： 48 65 6c 6c 6f 00 5a

## 我的解释

1. `mov si, message` 与 `mov al, [si]` 的区别： 前者是读地址，后者是读内存
2. `test al, al` 如何影响 `ZF` 和 `AL`：当  al != 0  ZF 就是 0，如果 = 0 ZF 就是 1， AL 不变
3. 为什么先判断 NUL： 因为 NUL 不用调用 call
4. `SI=0x7c45` 时会发生什么： [SI] 是 NUL，AL 读到 0；test 设置 ZF=1； jz 跳到 hang，不执行 putc 和 inc si，因此不会读取后面的 Z。
5. 哨兵 `Z` 的价值： 判断是否正确循环
6. putc 为什么没有破坏 `SI`： putc 没破坏 SI，是因为当前 putc 中没有任何写入 SI 的指令；这不是 call 的硬件保证

## 仍然不清楚的问题

- 
