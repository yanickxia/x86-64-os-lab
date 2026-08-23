# 第 31.5 课学习记录

本章是第 31–32 课之间的概念桥接章，不增加实验、预测题或绿灯记录。

## 我现在采用的心智模型

```text
PMM 分配 PA
→ kernel 通过 HHDM VA 访问 physical frame
→ VMM 把 PA 写进 page-table entry
→ MMU 在实际 load/store 时执行 VA → PA 翻译
```

## 需要牢牢记住的边界

- PMM 返回的是 physical frame 的 PA，不是普通 C pointer。
- 在当前 long-mode kernel 中，C pointer 被 CPU 当作 VA；某个 PA 只有拥有有效 mapping 后才能被 C 解引用。
- HHDM 提供 `VA = offset + PA` 的规则访问窗口，但 PTE/CR3 address bits 仍保存 PA。
- parent entry 指向下一张 page-table page；leaf PTE 指向最终 data frame。
- VA 的 bit fields 用来计算四级 index；`VMM_PAGE_ADDRESS_MASK` 用来从 entry 清掉 flags、取出 PA。
- software walker 返回的是 leaf PTE slot 的 pointer，caller 才能读取、填写或清除 mapping。

## 仍然不清楚的问题

-
