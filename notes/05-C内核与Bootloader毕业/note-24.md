# 第 24 课学习记录

日期：2026.08.11

> 本章是纯审计章：不新增代码，不设置红灯/绿灯，也不要求抄完整命令输出。读完讲义后运行一次聚合验收，再用自己的话填写四段。

## 聚合验收

### `make check-bootloader-graduation`

最后的 graduation summary：

```text
bootloader graduation audit passed:
  stage 1 → stage 2 execution boundary
  E820 → boot_info → RDI → C
  ELF PT_LOAD → .bss zero-fill → dedicated stack
  long mode + minimal #UD recovery remain intact
```

## 1. stage 1、stage 2 与 kernel 的职责边界

我的总结：

- stage 1：加载 stage 2；完成 A20、GDT、早期分页和 long-mode 切换；最终 handoff。
- stage 2：保存 boot drive；收集 E820；读取并应用 ELF `PT_LOAD`；发布 entry。
- kernel：校验 handoff，建立 IDT 教学入口，随后拥有全部 OS 策略。

## 2. kernel 接管时的最终 handoff

至少串起：long mode/恒等映射、`RDI=boot_info`、动态 ELF entry、zero-filled `.bss`、专用内核栈与 C ABI。

我的总结：

stage 2 先按 ELF 的 `PT_LOAD` 把 kernel 放进物理内存，并将 `p_memsz - p_filesz` 对应的 `.bss` 清零；随后把 ELF 的动态入口写入 `boot_info`。stage 1 建好低 2 MiB 恒等映射并进入 ring 0 long mode 后，令 `RDI=0x5000` 指向 `boot_info`，从 header offset 24 取得动态入口并跳转。kernel entry 再把 `RSP` 切到专用内核栈，保留 `RDI`，按 SysV ABI 调用 `kernel_main`。因此 C 接管时可以使用当前恒等映射和经校验的 handoff，但不能把它们当作最终页表或完整运行环境。

| offset | 字段 | 来源 | consumer 如何使用 |
| ---: | --- | --- | --- |
| 0 | magic `BINF` | stage 2 | 先确认结构类型 |
| 4 | version | stage 2 | 判断双方 layout 是否兼容 |
| 6 | E820 entry size 24 | stage 2 | 确认数组步长 |
| 8 | entry count | stage 2 的 E820 loop | 限制遍历上界 |
| 12 | capacity 32 | 自定义合同 | 防止 count 越过 buffer |
| 16 | entries physical `0x5020` | stage 2 | 找到 E820 array |
| 24 | kernel entry physical | ELF `e_entry` | stage 1 的最终 jump target |


## 3. 四条机器证据

分别为每条写一句“能证明”和“不能证明”：

### `check-stage2-handoff`

- 能证明：它同时检查 stage2 image 起点/尾部和 STAGE2OK。前者证明 bytes 被完整加载，后者证明 CPU 实际执行过入口。
- 不能证明：它不能证明 E820 或 ELF loader 正确。

### `check-e820-boot-info`

- 能证明：它证明 firmware entries 非空、stage 2 发布动态 count、RDI handoff 抵达 C，最终由 C 写出 E820COK!
- 不能证明：不能证明 type-1 ranges 已经排除 kernel/loader 占用，也不能证明 allocator 已建立。

### `check-elf-loader`

- 能证明：说明 stage 2 使用了 LBA 18 的 ELF。它还检查 dynamic entry、zero-filled probe、专用栈和 ELF64OK!。
- 不能证明：不能证明 loader 支持任意 ELF、高半地址、重定位或严格的页权限。

### `check-exception`

- 能证明：证明 ELF/stack 改造后，UD2 → vector 6 → C → IRETQ 仍能恢复到历史 hang
- 不能证明：不能证明完整 IDT；当前只有 vector 6 有效，`#PF` 等异常仍没有可靠入口。

## 4. 毕业边界

### 由成熟 bootloader 替换的教学限制（至少三项）

- 只支持 legacy BIOS/软盘镜像
- 写死 CHS/LBA 和读取长度
- 失败后输出 E 并死循环

### 由 kernel 后续实现的 OS 能力（至少三项）

- 物理页分配器
- 正式页表
- 完整 IDT

### 为什么现在切换 Limine 不会掩盖知识缺口

我的总结：第 25 课看到成熟协议返回 memory map、kernel address、framebuffer 或其他信息时，我们能够判断每个字段替代了自己哪一段实现，也能判断哪些事情仍必须由 kernel 完成。




## 仍然不清楚的问题

- 暂无。
