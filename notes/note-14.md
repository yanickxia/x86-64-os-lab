# 第 14 课学习记录

日期：2026.08.10

## 实验前推演（尚未运行）

在阅读正文第 1 节及以后内容、运行命令之前，根据教材输入 A–E 写出推导。下面已经填写的原始答案即使错误也保留。

1. 尚未修改时四个 symbol 的推导与结果：0x00000000, 0x00000002,0x0000000a, 0x0000000e
2. 尚未修改时 ELF entry point，以及 `ENTRY` 是否会搬动 symbol：应该不影响 
3. `kernel.bin` 的预测长度、前 16 字节，以及是否有 64 KiB 前导零：kernel.bin 512 字节，前 16 字节为 'KERNEL64'？应该有前导 0，因为长度不够
4. 尚未修改时的 debug console、最终 `RIP/CS`、`check-kernel-entry` 结果，以及绕过 ELF metadata 的环节：
5. location counter 改成 `0x10000` 后，四个 symbol 与 entry point：
6. 入口指令的 `kernel.elf` file offset、VMA/LMA、`kernel.bin` offset、`os.img` offset、guest physical/linear address：
7. `ENTRY(kernel_start)` 是 metadata 还是 CPU 指令，bootloader 是否读取：
8. 哪些产物是 ELF、哪些字节最终进入 guest RAM： 是 os.img 吧

### 实验前推演复盘

保留上面的原始推演作为学习记录；实验后修正如下：

1. 尚未修改时 `.text base=0`，所以四个 symbol 分别是 `0x0`、`0x2`、`0xa`、`0xe`。
2. `ENTRY(kernel_start)` 只令 ELF entry 等于 `kernel_start` 的最终值，因此尚未修改时 entry 是 `0x0`；它不会搬动 symbol。
3. 当前只有一个 512 字节 loadable `.text`，`objcopy` 从最低 loadable address 开始输出，所以 `kernel.bin` 仍为 512 字节，前 16 字节是 `EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE`，没有 64 KiB 前导零。
4. bootloader 绕过 ELF metadata，固定把 raw binary 放到 `0x10000` 并跳过去；因此仍输出 `HelloPTLK`、停在 `RIP=0x1000e`、保持 `CS=0x18 CS64`，`check-kernel-entry` 通过。
5. location counter 改成 `0x10000` 后，四个 symbol 是 `0x10000`、`0x10002`、`0x1000a`、`0x1000e`，ELF entry 是 `0x10000`。
6. 同一入口字节位于：`kernel.elf` file offset `0x1000`、VMA/LMA `0x10000`、`kernel.bin` offset `0`、`os.img` offset `0x200`、guest physical/linear `0x10000`。
7. `ENTRY(kernel_start)` 修改 ELF header metadata，不生成 CPU 指令；当前 bootloader 不解析也不读取它。
8. `kernel.o` 与 `kernel.elf` 以 ELF magic `7f 45 4c 46` 开头；`kernel.bin` 以 `EB 08...` 开头；`os.img` 开头是 boot sector。最终进入 RAM `0x10000` 的是 `kernel.bin` 的 512 字节内容。

## 红灯

- `make inspect-kernel-elf` 中的 ELF type、entry、`.text` 与 symbols：`kernel.elf` 是 `EXEC`，entry 为 `0x0`；`.text Size=0x200, VMA=LMA=0, File off=0x1000`；四个 symbols 为 `0x0/0x2/0xa/0xe`。
- `make check-kernel-elf` 原始失败输出：
  ```
  kernel ELF check: expected entry point 0x10000, got 0x0
  kernel ELF check: expected symbol '0000000000010000 T kernel_start'
  kernel ELF check: expected symbol '0000000000010002 T kernel_magic'
  kernel ELF check: expected symbol '000000000001000a T kernel_entry'
  kernel ELF check: expected symbol '000000000001000e T kernel_hang'
  kernel ELF check: expected .text VMA=0x10000 and size=0x200
  kernel ELF check: actual symbols:
  0000000000000000 T kernel_start
  0000000000000002 T kernel_magic
  000000000000000a T kernel_entry
  000000000000000e T kernel_hang
  ```
- 红灯时 `kernel.bin` 的长度与前 16 字节：512；`EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE`。
- 红灯时 `make check-debugcon`：`debug console check passed: received 'HelloPTLK' from I/O port 0xe9`。
- 红灯时 `make check-kernel-entry`：`kernel-entry check passed: payload executing at 0x1000e under CS=0x18 (CS64)`。
- 为什么这是 ELF 地址契约缺失，而不是运行时加载失败：raw `kernel.bin` 已被正确加载、执行，失败项只涉及 ELF entry、VMA 与 symbol metadata。

## 我的实现

```ld
/* 只记录由我补齐的 linker script 代码 */
. = 0x00010000;
```

## 绿灯原始观察

- `make check-kernel-elf` 完整输出：
  ```
  kernel ELF check passed: ELF64 entry=0x10000, .text VMA=0x10000, raw payload=512 bytes
  0000000000010000 T kernel_start
  0000000000010002 T kernel_magic
  000000000001000a T kernel_entry
  000000000001000e T kernel_hang
  ```
- `make inspect-kernel-elf` 的 ELF header：
  ```
  Class:                             ELF64
  Data:                              2's complement, little endian
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0x10000
  ```
- `x86_64-elf-nm -n build/kernel.elf`：
  ```
  0000000000010000 T kernel_start
  0000000000010002 T kernel_magic
  000000000001000a T kernel_entry
  000000000001000e T kernel_hang
  ```
- `.text` 的 Size/VMA/LMA/File off：`0x200 / 0x10000 / 0x10000 / 0x1000`。
- `kernel.bin` 的长度与前 16 字节：512；`EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE`。
- `make check-debugcon` 与 `make check-kernel-entry`：分别通过，输出 `HelloPTLK`，payload 停在 `RIP=0x1000e, CS=0x18 CS64`。
- 前 13 课完整回归结果：`check-boot/image/debugcon/segments/call/a20/gdt/protected/page-tables/long-mode/kernel-load/kernel-entry` 全部通过。

## 我的解释

1. `kernel.o` 与 `kernel.elf` 的 type、entry，以及 object 为什么没有最终地址：`kernel.o` 是 `REL`，entry 为 0；`kernel.elf` 是 `EXEC`，绿灯 entry 为 `0x10000`。object 保存 sections、symbols 与 relocations，但多个输入 section 尚未完成布局，所以只有 section-relative offset；linker 才决定最终地址并输出 executable。
2. 红绿灯 symbol value 与 `base + offset` 推演：symbol offsets 固定为 `0/2/a/e`。红灯 base 为 0，所以值是 `0/2/a/e`；绿灯 base 为 `0x10000`，所以值是 `0x10000/0x10002/0x1000a/0x1000e`。
3. location counter、output `.text`、`*(.text)` 的区别：location counter `.` 表示下一段输出的当前地址；左侧 `.text` 是 linker 创建的 output section；`*(.text)` 表示收集所有 input files 中名为 `.text` 的 input section。
4. ELF file offset/VMA/LMA、raw binary offset、image offset、guest address 的对应关系：
   ```
    build/kernel.elf file offset   0x1000   ELF header 与对齐之后
    ELF .text VMA/LMA             0x10000  linker script 决定
    build/kernel.bin file offset   0x0000   objcopy 已去掉 ELF metadata
    build/os.img file offset       0x0200   LBA 1
    guest physical/linear address  0x10000  BIOS 加载 + 恒等映射
   ```
5. 红灯仍能运行的原因，以及绝对 symbol reference 会带来的变化：bootloader 完全绕过 ELF metadata，把 raw bytes 固定放在 `0x10000`；载荷当前只用相对跳转，整段平移不会改变内部位移，因此仍能运行。若代码包含经 linker 按 base 0 修补的绝对 symbol address，运行时就会访问接近 0 的错误地址，而不是实际的 `0x10000` 区域。
6. `ENTRY(kernel_start)` 改变什么、不改变什么： 把 ELF header 的 e_entry 字段设置为 kernel_start 的最终 symbol value。它不移动 symbol、不生成 JMP，我们的 bootloader 也不会读取它。
7. `objcopy -O binary` 丢掉什么、保留什么，以及为何仍是 512 字节： 移除 ELF header、program/section headers、symbol table 和 debug information，只输出 loadable section 的内容。当前只有一个 512 字节 .text，所以 kernel.bin 仍以：EB 08 4B 45 52 4E 45 4C 36 34 B0 4B E6 E9 EB FE 开头，长度仍为 512
8. ELF 管线如何为 C 函数铺路，assembler/compiler/linker 如何分工： assembler 编译汇编代码为 object file，compiler 编译 C 代码为 object file，linker 合并 object file 为 ELF file。

## 仍然不清楚的问题

暂时没有；下一课进入 C 后，再结合真实的跨文件符号引用继续理解 relocation 与链接地址。
