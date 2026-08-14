# 第 30 课学习记录

日期：2026.08.14

> 第一次运行 `make check-kernel-address-space` 前完成“实验前预测”。不预测页面没有给出的 old CR3、精确 RSP 或 PML4E 物理值；错误答案原样保留，实验后写入“预测修订”。

## 实验前预测

### 1. 三个 PML4 indices

- custom target `0x0000123456789000`：
- HHDM base `0xffff800000000000`：
- kernel VA `0xffffffff80001000`：
- 计算过程：

### 2. preserved slot

- clone 后 `destination[custom_index]`：
- kernel/HHDM/stack 为什么仍可沿 old subtrees 翻译：

### 3. 当前红灯控制流

- 一定出现的 `VMM:*` markers：
- 一定不出现的 activation marker：
- `PF:DIAG:OK` 为什么仍出现：

## 红灯

### `make check-kernel-address-space`

```text

```

- 失败是否只位于 root clone：
- 第 29 课与第 28 课前置证据：

## 我的实现

### validation

- `NULL`：
- in-place clone：
- preserved index 边界：

### copy loop

```c

```

- 为什么 `preserved_index` 不被写入：

## 绿灯原始观察

### `make check-kernel-address-space`

```text

```

- old CR3：
- new CR3 / root PA：
- custom/kernel/HHDM/stack PML4 indices：
- kernel/HHDM/stack 的 old/copied entries：
- target before/after 与 HHDM after：
- 切换后 `PF:DIAG:OK`：

### 回归

```text
$ make check-kernel-page-table

$ make check-page-fault

$ make check-hhdm-page

$ make check-physical-pages

$ make check-limine-handoff

```

## 预测修订

> 每项填写“原预测 / 真实结果 / 错误原因或一致证据”，不要修改上面的原答案。

### 1. 三个 PML4 indices

- 原预测：
- 真实结果：
- 错误原因或一致证据：

### 2. preserved slot

- 原预测：
- 真实结果：
- 错误原因或一致证据：

### 3. 红灯控制流

- 原预测：
- 真实结果：
- 错误原因或一致证据：

## 我的解释

### 1. shallow copy 与 ownership

- 为什么复制 PML4 entries 后 code/stack/HHDM 可以继续工作：
- 为什么下级 tables 仍不是 kernel-owned：
- 对回收 bootloader memory 的约束：

## 仍然不清楚的问题

-
