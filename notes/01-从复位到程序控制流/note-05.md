# 第 5 课学习记录

日期：2026.08.08

## 实验前计算

1. call 后下一条指令地址： 0x7c15
2. putc 地址： 0x7c20
3. 相对位移： 0x000b
4. 进入 putc 时的 SP： 0x7bfe
5. 栈顶保存的 word：0x7c15

## 红灯

- `make check-debugcon`：debug console check passed: received 'X' from I/O port 0xe9
- `make check-call`： 
	Breakpoint 2, 0x0000000000007c15 in ?? ()
	FAIL: reached hang without entering putc; output was produced directly
	[Inferior 1 (process 1) detached]
	qemu-system-x86_64: terminating on signal 15 from pid 49790 (<unknown process>)
	make: *** [check-call] Error 1
- 为什么一个通过、一个失败： 因为现在是 直接输出到 io，然后就 nop 了

## 我的修改

```asm
; 记录替换后的指令
call putc
```

## 绿灯原始观察

- putc 入口 `SP`： 0x7bfe
- putc 入口栈顶 word： 0x7c15
- ret 后 `IP`： 0x7c15
- ret 后 `SP`：0x7c00
- debug console 输出：X
- call 机器码： E80B00

## 我的解释

1. 为什么返回地址是 `0x7c15`：putc 是 00007C20， 但是是 call 是在 00007C12， call 的下一个是 00007C15 ，栈上保存的是 call 后面那条指令的地址，
2. 相对位移怎样计算： 用  displacement = 0x7c20 - 0x7c15 = 0x000b 来计算
3. 删除 `ret` 会怎样： 删除 ret 后，CPU 不会返回调用者，而会继续执行 putc 后面的字节。本例会把填充区的 00 00 当作指令继续执行，控制流不再符合函数契约。
4. 为什么只看到 `X` 不足以证明调用了函数： 因为可能直接输出到 IO 的
5. call 与 push 的共同点：都会压入栈，SP = SP - 2

## 仍然不清楚的问题

- 
