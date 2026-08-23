# 第 33 课学习记录

日期：2026.08.23

## 实验前预测

root 已存在，data frame 已由脚手架单独分配，而 `PML4[0x25] == 0`。
mapper 还要从 PMM 分配几张 page-table pages？分别充当哪一级？为什么不是四张？

我的预测：

## 红灯

第一次运行 `make check-vmm-mapper` 的结果：

```text

```

## 我的实现

只概括这三步，不抄完整函数：

- 如何找到第一个 zero parent：
- 如何分配、清零并连接剩余 child tables：
- 成功时最后发布哪两个结果：

## 绿灯原始观察

粘贴 `make check-vmm-mapper` 最后四行即可：

```text

```

## 预测修订

- 原预测：
- 真实结果：
- 修订原因：

## 我的解释

为什么必须先清零并连接全部 child tables，最后才把第一个缺失 parent 写成 `PRESENT=1`？
如果顺序反过来，CPU 可能观察到什么？

我的回答：

## 课中追问汇总

-

## 仍然不清楚的问题

-
