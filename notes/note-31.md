# 第 31 课学习记录

日期：2026.08.16

## 实验前预测

handler 补上 PTE 并原样返回后，触发 fault 的 store 会被跳过还是重新执行？为什么？

我的预测：

## 红灯

第一次运行 `make check-demand-page` 的结果：

## 我的实现

只概括 `vmm_resolve_demand_write()` 的成功条件与最终状态变化，不必抄完整函数：

-

## 绿灯原始观察

粘贴 `make check-demand-page` 最后三行摘要即可：

```text

```

## 预测修订

原预测与真实结果是否一致？若不一致，用一行说明错在哪里：

## 我的解释

为什么第 19 课需要推进 `UD2` 的 saved `RIP`，本课却必须保留 faulting store 的 saved `RIP`？PTE 与 `INVLPG` 分别修复了什么？

我的回答：

## 仍然不清楚的问题

-
