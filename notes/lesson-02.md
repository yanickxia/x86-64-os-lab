# 第 2 课学习记录

日期：

## 红灯

第一次运行 `make check-boot` 的错误：expected 512 bytes, got 2

## 我的修改

- 填充表达式：times 510 - ($ - $$) db 0
- 签名表达式：dw 0xaa55

## 原始观察

- 文件大小：512
- 文件末尾两个字节： 55 aa
- GDB 命中时 `CS:IP`： 0x0:0x7c00
- 对应物理地址：0x7c00
- 文件与内存的比较结果： identical: build/boot.bin == memory[0x7c00..0x7dff] 

## 我的解释

1. `dw 0xaa55` 为什么显示为 `55 aa`： nasm 应该小端，所以是反的
2. `org 0x7c00` 的作用： 定位到 0x7c00 位置， 是告诉 nasm 这段代码的起始位置是 0x7c00 方便编译运行计算offset 应该
3. `cmp` 成功证明了什么： 内存里面和bin文件一样

## 仍然不清楚的问题

- 

