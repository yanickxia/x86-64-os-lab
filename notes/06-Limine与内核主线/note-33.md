# 第 33 课学习记录

日期：2026.08.24

## 实验前预测

### 1. create 与 reuse

root 与两个 data frames 都由 caller 提供。第一次映射遇到 `PML4[0x25] == 0`，第二次映射相邻 VA。
两次 `allocated_table_count` 分别是多少？新 frames 各充当哪一级？

我的预测：

### 2. unmap 后的四种状态

第二页 unmap 后，它的 leaf、三张 parent tables、data frame ownership 和 `free_pages` 应分别处于什么状态？

我的预测：

## 红灯

第一次运行 `make check-vmm-mapper` 的结果：

```text

```

## 我的实现

只概括 lifecycle，不抄完整函数：

- 如何找到第一个 zero parent：
- 如何分配、清零并连接剩余 child tables：
- 为什么相邻 mapping 不分配新 table：
- unmap 清除了什么，又刻意保留了什么：

## 绿灯原始观察

粘贴 `make check-vmm-mapper` 最后六行即可：

```text

```

## 预测修订

- 原预测：
- 真实结果：
- 修订原因：

## 我的解释

### 1. publication boundary

为什么必须先清零并连接全部 child tables，最后才把第一个缺失 parent 写成 `PRESENT=1`？
如果顺序反过来，CPU 可能观察到什么？

我的回答：

### 2. leaf、TLB 与 ownership

为什么 unmap 后 leaf 必须为 0，而 `free_pages` 必须保持不变？为什么 `INVLPG` 属于 caller？

我的回答：

## 课中追问汇总

-

## 仍然不清楚的问题

-
