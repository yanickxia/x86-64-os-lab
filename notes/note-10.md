# 第 10 课学习记录

日期：2026.08.09

## 实验前计算

1. `0x00007c00` 的 PML4 / PDPT / PD / PT index 与 page offset：PML4=0, PDPT=0, PD=0, PT=0x7, offset=0xc00
2. `0x00090000` 的 PML4 / PDPT / PD / PT index 与 page offset：PML4=0, PDPT=0, PD=0, PT=0x90, offset=0
3. 两个地址为什么命中同一个 2 MiB PD entry：因为算出来的上面 1 和 2 就固定到 同一个 PD
4. `P | RW`（flag 位见教材第 6 节）：文档中无说明，应该需要补充文档
5. `P | RW | PS`（flag 位见教材第 6 节）： 文档中无说明，应该需要补充文档
6. PML4[0]（entry 位于物理 `0x1000`；此处填 entry 保存的值）：0x1000
7. PDPT[0]（entry 位于物理 `0x2000`；此处填 entry 保存的值）：0x2000
8. PD[0]（entry 位于物理 `0x3000`；此处填 entry 保存的值）：0x3000
9. 三张表的 4 KiB 对齐检查：应该是对齐？

## 红灯

- debug console 输出：debug console check passed: received 'HelloPT' from I/O port 0xe9
- `make check-page-tables` 完整失败输出：

```text
page-table synchronization output: received 'HelloPT' from I/O port 0xe9
page-table check: expected PML4[0]=0x0000000000002003
page-table check: actual   PML4[0]=00001000: 0x0000000000000000
page-table check: expected PDPT[0]=0x0000000000003003
page-table check: actual   PDPT[0]=00002000: 0x0000000000000000
page-table check: expected PD[0]  =0x0000000000000083
page-table check: actual   PD[0]  =00003000: 0x0000000000000000
make: *** [check-page-tables] Error 1
```

- 为什么看到 `HelloPT` 不能证明页表 entry 正确：T 只能证明 setup_page_tables 返回了，不能证明 entry 正确。make check-page-tables 使用 QEMU monitor 的 xp（examine physical memory）直接读取。

## 我的实现

```asm
    mov dword [PML4_ADDR], PDPT_ADDR | 0x001 | 0x002
    mov dword [PDPT_ADDR], PD_ADDR | 0x001 | 0x002
    mov dword [PD_ADDR], 0 | 0x001 | 0x002 | 0x080
```

## 绿灯原始观察

- `make check-page-tables`：page-table check passed: low 2 MiB identity map is present
- PML4[0] 的物理内存值：0x0000000000002003
- PDPT[0] 的物理内存值：0x0000000000003003
- PD[0] 的物理内存值：0x0000000000000083
- 三条 `mov dword [absolute], immediate` 的反汇编与机器码：C7050010000003200000,C7050020000003300000,C7050030000083000000

## 我的解释

1. paging 与 segmentation 分别在地址形成链中做什么：segmentation：逻辑地址 → 线性地址, paging：线性地址 → 物理地址
2. 为什么使用多级页表树：这对大多数只用少量地址的程序极其浪费。多级页表把映射做成一棵基数树：只为真正使用的分支分配下一级表。
3. `0x7c00` 和 `0x90000` 在 2 MiB 映射中如何命中同一 leaf：因为 PD index   = (linear_address >> 21) & 0x1ff 结果就是一样,两个地址都小于 2 MiB，因此 PML4、PDPT、PD index 都为 0；它们的 PT index 不同，但 PS=1 后 PT index 属于 2 MiB page offset，不再查 PT。
4. 为什么需要恒等映射当前指令和栈：如果开分页后当前指令或栈没有映射，CPU 会立即产生 page fault。使用恒等的会更好切换,分页开启后，当前 EIP 和 ESP 的线性地址仍翻译到同数值物理地址，因此下一次取指和栈访问可以连续进行。
5. `EQU` 常量、运行时清零与页表 4 KiB 对齐的关系：EQU 只给数值起名字。REP STOSD 才真正清零并初始化 RAM。4 KiB 对齐是为了让地址低 12 位腾出来保存 flags。
6. 三个 entry 的地址部分与 flags：
   ```
    PML4[0]：P=1, RW=1
    PDPT[0]：P=1, RW=1
    PD[0]：P=1, RW=1, PS=1
    PML4[0]：地址部分 0x2000，flags 0x003
    PDPT[0]：地址部分 0x3000，flags 0x003
    PD[0]：物理 base 0，flags 0x083
   ```
7. `PS=1` 为什么能省掉 PT：PS=1 不是跳过 PML4，而是经过 PML4 → PDPT → PD 后，在 PD 提前结束，从而省略 PT。
8. `REP STOSD` 的次数、字节数与 `CLD` 的作用：CLD 把 direction flag 清零，保证 EDI 向高地址增长。REP STOSD: 重复 ECX 次，每次把 EAX 的 4 字节写到 ES:EDI，然后 EDI += 4，3072 × 4 = 12288 bytes = 3 × 4096 bytes
9.  为什么只写 entry 低 32 位：但本课的所有表和映射地址都低于 4 GiB，所以 entry 的高 32 位应为 0。清零循环已经把它们置零；练习只需要写每个 entry 的低 32 位。
10. 页表 entry 正确为什么不等于 paging / long mode 已开启： 还需要设置额外的,页表目前只是 RAM 数据；还没有设置 CR4.PAE、加载 CR3、设置 EFER.LME 和打开 CR0.PG。

## 仍然不清楚的问题

-
