# 第 28 课学习记录

日期：2026.08.13

> 第一次运行 `make check-page-fault` 前完成“实验前预测”；错误答案留在原处，实验后统一写进“预测修订”。

## 实验前预测

### 1. 合成 error code 推演

- `address`：0x00000000deadb000
- `error_code`：0x0000000000000017
- `rip`：0xffffffff80001234
- `present`：1
- `write`：1
- `user`：1
- `reserved_write`：0
- `instruction_fetch`：1
- `0x17` 的完整诊断：P + W + S + D

### 2. 本课真实触发的可推导结果

- `CR2`：0x0000400000000000
- error code：0x2
- `present/write/user/reserved_write/instruction_fetch`：0，1，0，0，0
- RIP 能确定的范围：0xffffffff8000....  发起 store 的 kernel instruction
- 为什么实验前不能写死精确 RIP：因为不确定

### 3. 当前红灯

- 一定出现的 marker：
    HHDM:PAGE:OK      出现
    PF:IDT:OK         出现
    PF:TRIGGER        出现
    PF:DECODE:FAIL    出现并 halt
- 一定不出现的 marker：
    PF:DIAG:OK 
- 控制流停在哪里：
    DECODE 阶段
- 为什么这已经证明 `#PF` 到达了 C：
    红灯已经证明 vector 14 能到 C。它不是“没有触发 page fault”，而是“原始证据尚未被你的纯 C 函数结构化”。


### 4. 若 handler 直接 `IRETQ`

- 下一步：形成 fault loop。
- 原因：触发 store 尚未完成，saved RIP 仍指向那条 store。如果 handler 什么也不修复就 IRETQ，CPU 会重新执行同一条指令，再次产生完全相同的 #PF，形成 fault loop。
- 本课为什么 halt：上述不如直接 fault

## 红灯

### `make check-page-fault`

```text
Limine/UEFI host tools check passed
page-fault check: #PF reached C, but its CR2/error-code evidence was not decoded
page-fault check: complete page_fault_decode() in kernel/faults.c
page-fault output: LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc9d | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc9b | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | PF:TRIGGER | PF:DECODE:FAIL
make: *** [check-page-fault] Error 1
```

- 失败准确位于哪一层：PF:DECODE:FAIL

## 我的实现

### 参数与原始证据

- NULL 检查：report == NULL
- 三个原始字段如何保存：
```
report->address = address;
report->rip = rip;
report->error_code = error_code;
```

### error-code bits

- bit 0 / `present`：0x0000000000000000
- bit 1 / `write`： 0x0000000000000001
- bit 2 / `user`： ：0x0000000000000000
- bit 3 / `reserved_write`： ：0x0000000000000000
- bit 4 / `instruction_fetch`：：0x0000000000000000

## 绿灯原始观察

### `make check-page-fault`

```text
Limine/UEFI host tools check passed
page-fault check passed: vector 14 reached C with CR2 and error-code evidence
page-fault state: CR2=0x0000400000000000, error=0x0000000000000002, RIP=0xffffffff800015ef
page-fault decode: P=0x0000000000000000, W=0x0000000000000001, U=0x0000000000000000, RSVD=0x0000000000000000, I=0x0000000000000000
```

- `PF:CR2`：0x0000400000000000
- `PF:ERROR`：0x0000000000000002
- `PF:RIP`：0xffffffff800015ef
- `P/W/U/RSVD/I`：P=0x0000000000000000, W=0x0000000000000001, U=0x0000000000000000, RSVD=0x0000000000000000, I=0x0000000000000000

### 回归

```text
$ make check-hhdm-page

$ make check-hhdm-page
Limine/UEFI host tools check passed
hhdm-page check passed: allocated PA became an HHDM VA and all 4096 bytes were cleared
hhdm-page state: offset=0xffff800000000000, PA=0x0000000000000000, VA=0xffff800000000000
hhdm-page contents: first/last 0xa5a55a5adeadbeef -> 0x0000000000000000

$ make check-physical-pages

$ make check-physical-pages
Limine/UEFI host tools check passed
physical-page check passed: two distinct aligned pages moved from free to kernel-owned

$ make check-limine-handoff
$ make check-limine-handoff
Limine/UEFI host tools check passed
Limine handoff check passed: UEFI → Limine → higher-half ELF entry → memory-map response
Limine handoff state: entry=0xffffffff80001000, output='LIMINE:ENTRY | LIMINE:MEMMAP:OK | PMM:FREE-BEFORE=0x000000000000cc9d | PMM:FIRST=0x0000000000000000 | PMM:SECOND=0x0000000000001000 | PMM:FREE-AFTER=0x000000000000cc9b | PMM:ALLOCATED=0x0000000000000002 | PMM:OK | HHDM:RESPONSE:OK | HHDM:OFFSET=0xffff800000000000 | HHDM:PA=0x0000000000000000 | HHDM:VA=0xffff800000000000 | HHDM:BEFORE-FIRST=0xa5a55a5adeadbeef | HHDM:BEFORE-LAST=0xa5a55a5adeadbeef | HHDM:AFTER-FIRST=0x0000000000000000 | HHDM:AFTER-LAST=0x0000000000000000 | HHDM:PAGE:OK | PF:IDT:OK | PF:TRIGGER | PF:CR2=0x0000400000000000 | PF:ERROR=0x0000000000000002 | PF:RIP=0xffffffff800015ef | PF:PRESENT=0x0000000000000000 | PF:WRITE=0x0000000000000001 | PF:USER=0x0000000000000000 | PF:RSVD=0x0000000000000000 | PF:FETCH=0x0000000000000000 | PF:DIAG:OK'
```

## 预测修订

> 对每项预测记录“原预测 / 真实结果 / 错误原因或一致证据”，不要修改上面的原答案。

> 导师复核（无需再次抄录）：合成输入的五个字段预测正确，但“P + W + S + D”把 bit 2 和 bit 4 的名称写反了；这里应读作 `P=1, W=1, U=1, RSVD=0, I=1`。真实触发、红灯控制流和 `IRETQ` 后果均与绿灯证据或机制推演一致；精确 RIP 本来就不能从实验前输入推出。

### 1. 合成输入

- 原预测：
- 真实结果：
- 错误原因或一致证据：

### 2. 真实触发

- 原预测：
- 真实结果：
- 错误原因或一致证据：

### 3. 红灯控制流

- 原预测：
- 真实结果：
- 错误原因或一致证据：

### 4. `IRETQ` 后果

- 原预测：
- 真实结果/机制结论：
- 错误原因或一致证据：

## 我的解释

### 1. 三份真实证据分别回答什么

- `CR2`：0x0000400000000000 
- error code：0x0000000000000002 
- RIP：0xffffffff800015ef 

### 2. 真实 error code 的完整诊断

- bit 分解：0x0000000000000002
- 一句话诊断：
```
P    = 0
W/R  = 1
U/S  = 0
RSVD = 0
I/D  = 0
```

### 3. bit 0 为什么不是 entry 的原始 Present bit

- `P=0`：non-present translation
- `P=1`：protection violation
- 为什么不能据此定位某一级 entry：P=0 不是“页面现在 present=0 的布尔打印”这么简单，它表示异常原因是翻译链中存在 non-present entry；P=1 表示 entry 存在，但权限检查失败。

### 4. 为什么尽早保存 `CR2`

- `CR2`：0x0000400000000000
- error code 与 saved RIP：0x0000000000000002   PF:RIP=0xffffffff800015ef

### 5. `PF:DIAG:OK` 的证据边界
不知道··
- 能证明：
- 不能证明：
- 距离可恢复 demand paging 仍缺：

> 导师讲解：它只证明本次固定 `#PF` 的 IDT 路由、C 入口、三份原始证据和 bits 0..4 解码正确；不能证明完整异常系统或缺页恢复已经完成。后者至少还需要地址空间/VMA policy、frame 分配与页表 mapping/TLB 操作，以及成功重试与 OOM/非法访问处理。这里是本课唯一新增的收束点，不要求把前四题已经记录过的数值再抄一遍。

## 仍然不清楚的问题

-
