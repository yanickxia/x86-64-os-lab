# 第 1 课学习记录

日期：

## 实验前预测

1. `RIP`：0
2. `CR0.PE` / `CR0.PG`：0
3. 第一条指令来自：不知道

## 原始观察

- `RIP`： 0xfff0
- `CS`： 0xf000
- `CR0`： 0x60000010
- `0xfffffff0` 的 16 字节：
- 第一条反汇编指令：

## 我的判断

1. 是否处于保护模式，证据是： `PE` 是 bit 0；为 1 表示启用保护模式。 (0x60000010 >> 0) & 1 = 0， 没有保护模式  
2. 是否开启分页，证据是： `PG` 是 bit 31；为 1 表示启用分页 (0x60000010 >> 31) & 1 = 0 也没有启动
3. 第一条指令的作用： 跳转到 0xf000 * 16 + 0xe05b 的地址
4. 是否支持第 0 课的预测：支持，没有分页不可能是 64位的

## 仍然不清楚的问题

- 

--- 16-bit decode of the reset vector ---
FFFFFFF0  EA5BE000F0        jmp word 0xf000:word 0xe05b
FFFFFFF5  30362F32          xor [0x322f],dh
FFFFFFF9  332F              xor bp,[bx]
FFFFFFFB  3939              cmp [bx+di],di
FFFFFFFD  00FC              add ah,bh
FFFFFFFF  00                db 0x00

我没看懂第一条指令的作用。 刚刚咨询学会了