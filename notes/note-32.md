# 第 32 课学习记录

日期：2026.08.19

## 实验前预测

demand store 尚未执行时，`0x000012345678a000` 的三个 parent entries 都 present，但 `PT[0x18a] == 0`。`vmm_walk_to_pte()` 应返回 `false`，还是返回 `true` 并交出一个 pointer？caller 随后通过这个 pointer 读到的 entry 值是什么？

我的预测：

## 红灯

第一次运行 `make check-page-table-walk` 的结果：

```text

```

## 我的实现

只概括每一级如何完成 `entry → next table PA → HHDM pointer`，以及成功时最终发布什么；不必抄完整函数：

- 

## 绿灯原始观察

粘贴 `make check-page-table-walk` 最后四行摘要即可：

```text

```

## 预测修订

原预测与真实结果是否一致？若不一致，错在混淆了 parent path 与 leaf mapping 的哪一层？

- 原预测：
- 真实结果：
- 修订原因：

## 我的解释

为什么 API 返回 `uint64_t **pte`，而不是只返回当前 entry 的 `uint64_t` 数值？这对后续 mapper 或 page-fault handler 有什么实际用途？

我的回答：

## 课中追问汇总

-

## 仍然不清楚的问题

-
