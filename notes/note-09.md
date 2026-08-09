# 第 9 课学习记录

日期：2026.08.09

## 实验前计算

1. 红灯时 CR0： 0x00000010
2. 设置 PE 后的 CR0： 0x00000011
3. PE 位编号：0 位置
4. far jump 的 selector： 0x0008
5. far jump 的 offset：0x7c90
6. far jump 的五个机器码字节： ea 90 7c 08 00
7. data selector： index = 2， selector = 0x10

## 红灯

- debug console 输出： debug console check passed: received 'HelloP' from I/O port 0xe9
- `make check-protected`：
    ```
    protected-mode check: expected CR0.PE=1, CS=0x0008, DS=SS=0x0010
    protected-mode check: CR0=00000010 CR2=00000000 CR3=00000000 CR4=00000000
    protected-mode check: CS =0000 00000000 0000ffff 00009b00
    protected-mode check: DS =0000 00000000 0000ffff 00009300
    protected-mode check: SS =0000 00000000 0000ffff 00009300
    ```
- 红灯时的 `CR0`：00000010
- 红灯时的 `CS`：0000 00000000 0000ffff 00009b00
- 红灯时的 `DS/SS`：0000 00000000 0000ffff 00009300
- 为什么输出 `HelloP` 仍不能证明进入保护模式：I/O 输出只是程序行为，不足以证明 CPU 模式。模式结论必须来自 CR0、段 selector 和 descriptor 状态。

## 我的实现

```asm
; 记录 CR0.PE + far jump 序列
enter_protected_mode:
    cli
    mov eax, cr0
    or eax, 1
    mov cr0, eax ; 设置 CR0.PE 为 1
    jmp 0x0008:protected_mode_entry ; 进入保护模式
```

## 绿灯原始观察

- `make check-protected`： protected-mode check passed: CR0.PE=1, CS=0x0008, DS=SS=0x0010
- debug console 输出：debug console check passed: received 'HelloP' from I/O port 0xe9
- 绿灯时的 `CR0`：00000011
- 绿灯时的 `CS`：CS=0x0008
- 绿灯时的 `DS/SS`： DS=SS=0x0010
- 实模式切换序列的机器码：FA 0F20C0 6683C801 0F22C0 EA907C0800
- 32 位入口的机器码：66B81000 8ED8 8EC0 8ED0 BC00000900 B050 E6E9 EBFE

## 我的解释

1. PE 与 far jump 分别改变什么：CR0.PE=1 启用保护模式的全局规则；far jump 把 0x08 装入 CS，并从 GDT 加载 CS 的隐藏缓存，包括 base/limit/access/D=1，然后跳到 0x7c90。
2. 为什么必须保留 CR0 的其他位：CR0.PE 位是唯一改变的位，其他位保持不变。其他位还有其他用处，不能被改变。
3. 为什么切换前执行 `CLI`： 当前启动代码在实模式初始化后执行过 STI，但我们还没有建立保护模式 IDT。如果在切换窗口收到可屏蔽中断，CPU 会按保护模式规则解释中断入口，而相应的 IDT 和处理函数尚不存在，结果通常是连续异常并最终 triple fault/reset。
4. near jump 为什么不能代替 far jump：near jump 只改变当前代码段内的 IP/EIP，不会重新加载 CS。far jump 则会改变 CS，需要重新加载 CS selector。
5. far jump 如何使用 selector `0x08`：
   ```
   index = 0x08 >> 3 = 1
    TI    = 0
    RPL   = 0
   ```
6. `bits 32` 为什么不是 CPU 指令： bits 16 和 bits 32 只告诉 NASM应该生成哪种默认编码，它们不会产生任何机器码，也不能改变 CPU 模式。
7. 为什么重新加载 `DS/ES/SS`：far jump 只重新加载 CS，不会自动改变数据段和栈段。保护模式入口已经由脚手架提供
8. 为什么重新设置 `ESP`：新栈使用 SS:ESP = 0x10:0x00090000。因为 data descriptor base 为 0，线性栈顶就是 0x00090000。栈仍向低地址增长。
9.  CS 的可见 selector 与隐藏 descriptor cache：CS 可见部分保存 selector 0x0008；隐藏部分缓存 descriptor 的 base、limit、类型、权限、DPL、P、G 和 D 等属性
10. 为什么暂时停在 32 位而不是直接进入 long mode：。当前代码描述符是 L=0, D=1，而且还没有建立 PML4 页表、设置 CR4.PAE、写入 CR3、设置 EFER.LME 和开启 CR0.PG，所以现在只是32位保护模式。

## 仍然不清楚的问题

-
