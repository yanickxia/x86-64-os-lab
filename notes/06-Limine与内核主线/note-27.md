# 第 27 课学习记录

日期：2026.08.12

> 先读讲义第 0–10 节并查看 `kernel/hhdm.h`、`kernel/hhdm.c`，再填写预测。第一次运行 `make check-hhdm-page` 前完成；错误预测不要覆盖，实验后在“预测修订”中修正。

## 实验前预测

### 1. 给定地址计算

- `virtual_page`：0xffff800000003000
- `page[0]` 的 VA：0xffff800000003000
- `page[511]` 的 VA：xffff800000202000
- `page[512]` 为什么越界 PMM_PAGE_SIZE / sizeof(*page) 的上限就是 512 个，index = 511

### 2. 三个边界条件

- 合法输入且 `physical_address = 0x0`： 函数需要通过 *virtual_page 写回结果；若 output pointer 本身为 NULL，写回会触发无效内存访问。
- `physical_address = 0x1234`：PA 必须 4 KiB 对齐 所以不对
- `offset = 0xfffffffffffff000`、`PA = 0x2000`：加法不能溢出

### 3. 当前红灯

- 一定出现的 marker：
  LIMINE:MEMMAP:OK      出现
  PMM:OK                出现
  HHDM:RESPONSE:OK      出现
  HHDM:PREPARE:FAIL     出现并 halt
- 一定不出现的 marker：HHDM:PAGE:OK
- 控制流停在哪里：准备 PAGE 失败
- 为什么第 26 课仍然成立，本课却应红灯：因为没走到呗

### 4. `HHDM:PAGE:OK` 的证据边界

- 它新增证明：HHDM 读取成功了
- 它是否证明已经拥有 kernel-owned page tables，为什么：不能，只是分页成功了

## 红灯

### `make check-hhdm-page`

```text
$ make check-hhdm-page
Limine/UEFI host tools check passed
hhdm-page check: HHDM exists, but the allocated frame was not translated and cleared
hhdm-page check: complete hhdm_prepare_page() in kernel/hhdm.c
hhdm-page output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cca0 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc9e | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:PREPARE:FAIL
make: *** [check-hhdm-page] Error 1
```

- 失败准确位于哪一层：but the allocated frame was not translated and cleared

## 我的实现


### 输入检查

- output pointer：virtual_page == NULL
- 4 KiB alignment： physical_address % 4096 != 0
- addition overflow：physical_address > UINT64_MAX - hhdm_offset

### PA → VA

- 计算与 pointer cast：uint64_t *page = (uint64_t *)(uintptr_t)(hhdm_offset + physical_address);
- 为什么没有写死 offset：由 Limine 的 HHDM response 动态提供

### 清零整页

- 循环次数及计算：(size_t index = 0; index < PMM_PAGE_SIZE / sizeof(*page); ++index
- 第一个和最后一个合法 index：0， 511

## 绿灯原始观察

### `make check-hhdm-page`

```text
Limine/UEFI host tools check passed
hhdm-page check passed: allocated PA became an HHDM VA and all 4096 bytes were cleared
hhdm-page state: offset=0xffff800000000000, PA=0x0000000000000000, VA=0xffff800000000000
hhdm-page contents: first/last 0xa5a55a5adeadbeef -> 0x0000000000000000
```

摘录真实状态：

- `HHDM:OFFSET`：0xffff800000000000
- `HHDM:PA`：0x0000000000000000
- `HHDM:VA`：0xffff800000000000
- `BEFORE-FIRST` / `BEFORE-LAST`：0xa5a55a5adeadbeef / 0xa5a55a5adeadbeef
- `AFTER-FIRST` / `AFTER-LAST`：0x0000000000000000/ 0x0000000000000000

### 回归

```text
$ make check-physical-pages

Limine/UEFI host tools check passed
physical-page check passed: two distinct aligned pages moved from free to kernel-owned
physical-page state: first=0x0000000000000000, second=0x0000000000001000, free=0x000000000000cca0->0x000000000000cc9e, allocated=0x0000000000000002

$ make check-limine-handoff
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cca0 | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc9e | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK'
```

## 预测修订

> 本节在实验后填写；“实验前预测”保持第一次作答原样，不回头覆盖。

### 1. `page[511]` 的地址

- 原预测：`0xffff800000202000`
- 真实计算：

  ```text
  page[511] = VA + 511 × sizeof(uint64_t)
            = 0xffff800000003000 + 511 × 8
            = 0xffff800000003000 + 0xff8
            = 0xffff800000003ff8
  ```

- 错误原因：原预测没有按 `uint64_t *` 的 8-byte pointer arithmetic 逐项计算。

### 2. 合法的 `physical_address = 0`

- 原预测：误答成了 `virtual_page == NULL` 时 output parameter 无法写回。
- 真实结果：题目中的 `physical_address` 为 0，不是 `virtual_page` 为 `NULL`；其他参数合法时应成功。
- 错误原因：混淆了 physical-address 参数和 output-pointer 参数。返回指针是 `HHDM offset + 0`，不是 C null pointer。

### 3. `HHDM:PAGE:OK` 的证据边界

- 原预测：只写了“HHDM 读取成功”“分页成功”，范围不准确。
- 真实结果：它证明 response 存在、`VA = offset + PA`，而且 kernel 通过该 VA 把完整 4096-byte frame 从 sentinel 清零。
- 错误原因：把“使用 Limine 现有 HHDM mapping”误写成了“已经拥有 kernel-owned page tables”；本课没有创建、连接或切换新页表。

## 我的解释

### 1. 真实地址关系

- 三个真实值：HHDM offset： 0xffff800000000000 、PA: 0x0000000000000000 和 VA: 0xffff800000000000
- 十六进制加法：0x0000000000000000 + 0xffff800000000000 = 0xffff800000000000

### 2. 为什么 PA 0 不会成为 null pointer

PA = 0
VA = HHDM offset + 0
   = 0xffff800000000000
C 实际解引用的是这个非零 HHDM VA，而不是 (void *)0。

### 3. sentinel 与完整清零证据

- 为什么先写 sentinel：方便验证结果
- 首尾检查能证明：这一页开头和结尾的两个 64-bit word 已被清零
- `page_is_zero()` 额外证明：全页都是 0

### 4. pointer arithmetic 与循环次数

page 的类型是 uint64_t *
page + 1 跨过 sizeof(uint64_t) = 8 bytes = 64 bits
循环次数 = PMM_PAGE_SIZE / sizeof(*page)
         = 4096 / 8
         = 512

### 5. ownership、mapping、contents 与 page-table 角色

ownership：我们的 PMM 管理
mapping：当前由 Limine 建立的 HHDM/page tables 提供
contents：由我们的 kernel 初始化

当前不能叫 page table，不只是“还没有初始化”——它已经被清零初始化了。真正缺少的是：
尚未指定它属于 PML4、PDPT、PD 或 PT 哪一级；
尚未填写合法 page-table entries；
尚未连接进 page-table tree；
CPU 的 CR3 仍指向 Limine 的页表根。

## 仍然不清楚的问题

-
