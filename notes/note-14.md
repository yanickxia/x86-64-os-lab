# 第 14 课学习记录

日期：2026.08.10

## 加速轨道结论

本课改为基础设施桥接章，由导师完成 linker script 与构建验收；下面已经写下的原始推演保持不变，不要求继续补满所有观察题。

- object 保存 sections、symbols 与 relocations；linker 决定最终地址并输出 `kernel.elf`。
- `.text`、ELF entry 与 `kernel_start` 必须匹配 bootloader 的真实加载/跳转地址 `0x10000`。
- bootloader 读取 raw `kernel.bin`；`kernel.elf` 用于链接、符号验证和后续调试。
- 验收证据：`make check-kernel-elf` 通过后，`kernel_start=0x10000`、`.text VMA=0x10000`，raw payload 仍为 512 字节。

## 实验前推演（尚未运行）

在阅读正文第 1 节及以后内容、运行命令之前，根据教材输入 A–E 写出推导。下面已经填写的原始答案即使错误也保留。

1. 尚未修改时四个 symbol 的推导与结果：0x00000000, 0x00000002,0x0000000a, 0x0000000e
2. 尚未修改时 ELF entry point，以及 `ENTRY` 是否会搬动 symbol：应该不影响 
3. `kernel.bin` 的预测长度、前 16 字节，以及是否有 64 KiB 前导零： kernel.bin 512 字节，前 16 字节为 'EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE'？没有前导 0 
4. 尚未修改时的 debug console、最终 `RIP/CS`、`check-kernel-entry` 结果，以及绕过 ELF metadata 的环节：
5. location counter 改成 `0x10000` 后，四个 symbol 与 entry point：
6. 入口指令的 `kernel.elf` file offset、VMA/LMA、`kernel.bin` offset、`os.img` offset、guest physical/linear address：
7. `ENTRY(kernel_start)` 是 metadata 还是 CPU 指令，bootloader 是否读取：
8. 哪些产物是 ELF、哪些字节最终进入 guest RAM： 是 os.img 吧

## 红灯

- `make inspect-kernel-elf` 中的 ELF type、entry、`.text` 与 symbols：
- `make check-kernel-elf` 原始失败输出：
  ```
  ```
- 红灯时 `kernel.bin` 的长度与前 16 字节：
- 红灯时 `make check-debugcon`：
- 红灯时 `make check-kernel-entry`：
- 为什么这是 ELF 地址契约缺失，而不是运行时加载失败：

## 我的实现

```ld
/* 只记录由我补齐的 linker script 代码 */
```

## 绿灯原始观察

- `make check-kernel-elf` 完整输出：
  ```
  ```
- `make inspect-kernel-elf` 的 ELF header：
  ```
  ```
- `x86_64-elf-nm -n build/kernel.elf`：
  ```
  ```
- `.text` 的 Size/VMA/LMA/File off：
- `kernel.bin` 的长度与前 16 字节：
- `make check-debugcon` 与 `make check-kernel-entry`：
- 前 13 课完整回归结果：

## 我的解释

1. `kernel.o` 与 `kernel.elf` 的 type、entry，以及 object 为什么没有最终地址：
2. 红绿灯 symbol value 与 `base + offset` 推演：
3. location counter、output `.text`、`*(.text)` 的区别：
4. ELF file offset/VMA/LMA、raw binary offset、image offset、guest address 的对应关系：
5. 红灯仍能运行的原因，以及绝对 symbol reference 会带来的变化：
6. `ENTRY(kernel_start)` 改变什么、不改变什么：
7. `objcopy -O binary` 丢掉什么、保留什么，以及为何仍是 512 字节：
8. ELF 管线如何为 C 函数铺路，assembler/compiler/linker 如何分工：

## 仍然不清楚的问题

-
