# Freestanding C 与内核代码参考

这不是一份完整的 C 语言教材，而是本课程的跨课速查页。它只集中解释我们在 x86-64 kernel 中真正会用到、并且容易和机器模型混淆的 C 语法。

遇到一个新写法时，先回答三件事：

1. C 编译器如何解释它；
2. 它对应多少 bytes、什么地址或哪些 bits；
3. 在没有操作系统和完整标准库的 kernel 环境里，它依赖什么前提。

后续课程首次引入新的 C 语法时，会同步补到本页。

## 1. Hosted C 和 freestanding C

普通应用运行在 hosted environment 中：操作系统和 C runtime 准备进程、栈、标准库，最后调用 `main()`。

我们的 kernel 属于 freestanding environment：bootloader 交出 CPU 和一份启动协议数据，内核自己负责其余环境。项目使用的关键选项包括：

```text
-std=c11
-ffreestanding
-fno-builtin
-fno-stack-protector
-mno-red-zone
```

它们不等于“C 语言失效”，而是说明不能默认拥有普通应用的完整运行时：

- 入口不必是 `main()`，本项目由 linker 和 boot protocol 决定入口；
- 不能因为写了 `printf()`、`malloc()` 或 `memset()` 就假设已有实现；
- 栈、异常入口、内存分配、输出设备等基础设施要由 bootloader 或 kernel 明确建立；
- `<stdint.h>`、`<stddef.h>`、`<stdbool.h>` 这类编译器可用的基础类型头仍可使用。

`-ffreestanding` 也不会自动防止越界、空指针、未对齐访问或数据竞争。它只是改变编译环境合同，不替内核提供安全性。

## 2. `.c`、`.h`、声明和定义

可以先用一句话区分：

```text
.h 描述“别人可以怎样使用”
.c 实现“它实际上怎样工作”
```

头文件通常放类型、宏和函数声明：

```c
#ifndef KERNEL_FAULTS_H
#define KERNEL_FAULTS_H

#include <stdbool.h>
#include <stdint.h>

struct page_fault_report;

bool page_fault_decode(uint64_t address,
                       uint64_t error_code,
                       uint64_t rip,
                       struct page_fault_report *report);

#endif
```

`.c` 文件包含头文件并给出函数定义：

```c
#include "faults.h"

bool page_fault_decode(/* ... */) {
    /* function body */
}
```

这里的术语是：

- **声明（declaration）**：告诉编译器名字和类型；
- **定义（definition）**：真正分配对象或提供函数体；
- **translation unit**：一个 `.c` 文件经过 `#include` 和宏展开后交给编译器的整体；
- **linker**：把多个 translation units 产生的 object files 中的引用与定义连接起来。

`#ifndef` / `#define` / `#endif` 是 include guard，防止同一头文件在一个 translation unit 中重复展开。

文件作用域的 `static` 会把名字限制在当前 translation unit，适合不想暴露给其他模块的 helper 或状态：

```c
static void debug_putc(char value) {
    /* only this .c file can name debug_putc */
}
```

## 3. 本课程常见的基础类型

### 3.1 固定宽度整数

kernel 经常需要精确对应寄存器、协议字段和页表项，因此优先使用 `<stdint.h>` 中的固定宽度类型：

| 类型 | 本项目中的宽度 | 常见用途 |
| --- | ---: | --- |
| `uint8_t` | 8 bits | byte、端口数据、descriptor 字段 |
| `uint16_t` | 16 bits | selector、端口号 |
| `uint32_t` | 32 bits | 协议字段、部分寄存器值 |
| `uint64_t` | 64 bits | PA、VA、页表项、x86-64 寄存器 |
| `uintptr_t` | 能保存目标平台对象指针的无符号整数类型 | 地址整数与指针之间的显式边界 |

不要把 `int`、`long` 的宽度靠记忆猜出来；它们会受 ABI 影响。协议或硬件布局需要精确宽度时，直接写固定宽度类型。

### 3.2 `size_t`

`size_t` 是 `sizeof` 的结果类型，也适合表示对象大小和数组下标：

```c
for (size_t index = 0; index < word_count; ++index) {
    /* ... */
}
```

它表示“足以描述当前目标平台任意对象大小的无符号整数”，不是固定等于 `uint64_t` 的语言承诺。

### 3.3 `bool`

引入 `<stdbool.h>` 后可使用 `bool`、`true` 和 `false`：

```c
bool write = (error_code & PAGE_FAULT_WRITE) != 0;
```

显式写 `!= 0` 可以清楚区分原始 mask 值和规范化后的真假值。

### 3.4 整数常量

需要明确得到 `uint64_t` 语义时可使用 `UINT64_C`：

```c
#define PAGE_SIZE UINT64_C(4096)
#define PAGE_FAULT_WRITE (UINT64_C(1) << 1)
```

地址和位模式通常用十六进制，因为一个 hex digit 正好对应 4 bits：

```text
0x1000 = 4096
0x2    = 0b0010
```

## 4. 指针、地址值、PA 和 VA

下面四个东西不能混成一个概念：

```text
uint64_t value             一个 64-bit 数值
uint64_t *pointer          指向 uint64_t 对象的指针
physical address / PA      物理内存编号，本身通常不能被 C 直接解引用
virtual address / VA       当前页表翻译下，CPU 用来访问内存的地址
```

第 27 课的边界是：

```c
uint64_t virtual_address = hhdm_offset + physical_address;
uint64_t *page = (uint64_t *)(uintptr_t)virtual_address;
```

分两次 cast 是在公开意图：先把 64-bit 地址值解释成可容纳指针的整数 `uintptr_t`，再把它解释成 `uint64_t *`。这依赖本项目固定的 x86-64 编译器、ABI 和 Limine mapping 合同，不是任意 C 程序都能凭空把数字变成有效指针。

### 4.1 `&` 和 `*`

```c
uint64_t value = 7;
uint64_t *pointer = &value;  /* & 取得 value 的地址 */
uint64_t copy = *pointer;    /* * 读取 pointer 指向的对象 */
*pointer = 9;                /* * 写入 pointer 指向的对象 */
```

同一个 `*` 在声明和表达式里的角色不同：

```text
uint64_t *pointer;   声明 pointer 是指针
value = *pointer;    解引用 pointer
```

### 4.2 null pointer 不等于物理地址 0

`NULL` 用来表达“没有对象指针”：

```c
if (report == NULL) {
    return false;
}
```

它不是一种通用的整数失败值。PMM 返回的 PA 是整数；如果物理 frame 0 在合同中允许分配，那么 `physical_address == 0` 仍可能成功。API 必须另外返回 `bool`，或明确保留一个不可能的 PA 作为失败标记。

更不能认为解引用 `(void *)0` 必然触发 fault。是否 fault 取决于当前页表是否映射 VA 0；早期课程的低地址恒等映射就展示过这个区别。

### 4.3 指针算术按元素移动

```c
uint64_t *page = /* one mapped 4 KiB frame */;
page + 1;
```

`page + 1` 前进的是 `sizeof(uint64_t)`，即 8 bytes，而不是 1 byte。所以一张 4 KiB 页表页能放：

```text
4096 bytes / sizeof(uint64_t)
= 4096 / 8
= 512 entries
```

最后一个合法元素是 `page[511]`；`page[512]` 已经越过这一个 4 KiB frame。

### 4.4 output parameter 与二级指针

函数有时既要返回成功/失败，又要把一个结果交给 caller。本课程使用 `bool + output parameter`：

```c
bool pmm_alloc_page(struct pmm_allocator *allocator,
                    uint64_t *physical_address);
```

caller 把局部变量的地址传入；函数通过 `*physical_address` 写回一个 `uint64_t`。

如果要写回的结果本身也是 pointer，就需要 pointer-to-pointer：

```c
bool vmm_walk_to_pte(uint64_t root_pa,
                     uint64_t hhdm_offset,
                     uint64_t virtual_address,
                     uint64_t **pte);

uint64_t *leaf = NULL;
bool found = vmm_walk_to_pte(root_pa, hhdm_offset, address, &leaf);
```

从变量名向外读：

| 表达式 | 类型/含义 |
| --- | --- |
| `leaf` | `uint64_t *`，PTE 在哪里 |
| `&leaf` | `uint64_t **`，caller 的 pointer 变量在哪里 |
| `*pte = some_pointer` | 函数把找到的 pointer 写回 `leaf` |
| `**pte` | 经过两次解引用，读取或修改最终的 64-bit PTE 内容 |

失败路径通常不应修改 output。先用局部变量完成全部验证，成功时最后一次性发布：

```c
*pte = &table[index];
return true;
```

二级指针本身不保证安全。函数仍必须验证 `pte != NULL`；caller 也只能在返回 `true` 后使用写回的 pointer。

## 5. `sizeof`、数组和边界

`sizeof(expression)` 返回表达式类型占用的 bytes；通常不会求值该表达式：

```c
uint64_t *page = /* ... */;
size_t entry_size = sizeof(*page);       /* 8 */
size_t entry_count = 4096 / sizeof(*page); /* 512 */
```

写 `sizeof(*page)` 比重复写 `sizeof(uint64_t)` 更能跟随变量类型变化。

数组下标等价于按元素做指针偏移后解引用：

```c
page[index] == *(page + index)
```

但 `sizeof` 最容易踩到数组退化问题：

```c
uint64_t entries[512];
sizeof(entries);              /* 整个数组的 bytes：4096 */

void clear(uint64_t entries[512]) {
    sizeof(entries);          /* 此处 entries 是 pointer，不再是整个数组 */
}
```

把数组传给函数时，应同时传入元素数或 byte 数，不能在函数里靠 `sizeof(parameter)` 恢复原长度。

### 5.1 半开区间

遍历内存范围时优先使用 `[begin, end)`：包含 `begin`，不包含 `end`。

```c
for (size_t index = 0; index < entry_count; ++index) {
    page[index] = 0;
}
```

`<` 与半开区间配合，可让循环次数精确等于 `entry_count`；写成 `<=` 会多访问一个元素。

## 6. `struct`、`.`、`->` 和初始化

结构体把一组有名字的字段组织成一个类型：

```c
struct page_fault_report {
    uint64_t address;
    uint64_t error_code;
    uint64_t rip;
    bool present;
    bool write;
};
```

对象使用 `.`，指向对象的指针使用 `->`：

```c
struct page_fault_report report = {0};
report.write = true;

struct page_fault_report *output = &report;
output->write = true;  /* 等价于 (*output).write = true */
```

designated initializer 按字段名初始化，不依赖肉眼记住字段顺序：

```c
struct range range = {
    .base = UINT64_C(0x1000),
    .length = UINT64_C(0x3000),
};
```

编译器可能为了对齐在字段之间加入 padding。因此 C `struct` 不能仅凭“字段宽度相加”就假定等于硬件或磁盘格式；需要匹配外部二进制协议时，必须同时核对布局、对齐、字节序和 ABI。

## 7. bit mask 与移位

页表项、异常 error code 和设备寄存器经常把多个布尔字段编码进一个整数。

### 7.1 测试 bit

```c
#define PAGE_FAULT_PRESENT (UINT64_C(1) << 0)
#define PAGE_FAULT_WRITE   (UINT64_C(1) << 1)

report->present = (error_code & PAGE_FAULT_PRESENT) != 0;
report->write = (error_code & PAGE_FAULT_WRITE) != 0;
```

`&` 是 bitwise AND；`&&` 是 logical AND，不能互换。

### 7.2 设置和清除 bit

```c
entry |= PRESENT;     /* set */
entry &= ~WRITABLE;   /* clear */
```

多个 flag 使用 bitwise OR 合并：

```c
entry = frame_address | PRESENT | WRITABLE;
```

位运算优先使用无符号类型。移位量必须小于左操作数的 bit width；例如 64-bit 值不能移位 64 或更多。

### 7.3 提取字段

若一个字段从 bit 12 开始：

```c
uint64_t frame_address = entry & UINT64_C(0x000ffffffffff000);
uint64_t index = (virtual_address >> 12) & UINT64_C(0x1ff);
```

`0x1ff` 是 9 个 1，可留下 `0..511`。掩码必须来自对应架构或协议定义，不能只因为某次 QEMU 输出“看起来能用”就随意截位。

## 8. `const`、`volatile` 和它们做不到的事

### 8.1 `const`

```c
bool pmm_init(const struct limine_memmap_response *memory_map);
```

这里表示该函数通过这个指针读取 memory map，不应通过它修改对象。它是接口约束和编译器检查，不代表内存位于只读物理页，也不代表其他代码绝对无法修改同一对象。

读指针声明时，从变量名向外看：

```c
const uint64_t *p;       /* p 指向的 uint64_t 不通过 p 修改 */
uint64_t *const p2 = q;  /* p2 自己不能再指向别处 */
```

### 8.2 `volatile`

`volatile` 告诉编译器：该对象的访问是可观察行为，不能像普通内存那样随意省略或合并。

课程中的故障触发使用：

```c
*(volatile uint64_t *)(uintptr_t)fault_address = UINT64_C(0x28);
```

它防止优化器因为这次 store 的普通 C 结果无人读取而删除 store。在设备 MMIO、由硬件异步更新的对象或特定启动协议对象中也常见。

`volatile` **不是**：

- 原子操作；
- CPU memory barrier；
- 多核线程同步；
- 锁；
- “这个指针一定有效”的证明。

并发课程会单独引入 atomics、锁和架构内存顺序，不能用 `volatile` 代替。

## 9. 返回值和 output parameter

C 函数只能直接返回一个值。需要同时返回成功状态和结果时，本课程常用：`bool` 返回状态，通过指针发布结果。

```c
bool hhdm_prepare_page(uint64_t hhdm_offset,
                       uint64_t physical_address,
                       uint64_t **virtual_page);
```

调用者：

```c
uint64_t *page = NULL;

if (!hhdm_prepare_page(hhdm_offset, physical_address, &page)) {
    /* failure policy */
}
```

被调用者：

```c
if (virtual_page == NULL) {
    return false;
}

/* validate and prepare first */
*virtual_page = page;
return true;
```

类型层级要逐层读：

```text
uint64_t       value
uint64_t *     pointer to value
uint64_t **    pointer to the caller's pointer
```

好的 output-parameter 合同应说明失败时是否保持原值。最稳妥的实现通常在全部校验和操作成功后才写 `*output`，避免调用者拿到半成品。

## 10. 整数溢出、对齐和范围校验

### 10.1 unsigned addition overflow

下面的加法可能回绕到较小值：

```c
uint64_t virtual_address = hhdm_offset + physical_address;
```

在相加前检查：

```c
if (physical_address > UINT64_MAX - hhdm_offset) {
    return false;
}
```

无符号整数溢出按模回绕；有符号整数溢出则是 undefined behavior。地址和长度运算即使使用无符号数，也必须主动检查结果是否仍符合地址空间合同。

### 10.2 对齐

4 KiB frame 的起始 PA 必须是 `0x1000` 的倍数：

```c
if (physical_address % PMM_PAGE_SIZE != 0) {
    return false;
}
```

当 size 是 2 的幂时，也常见等价 bit test：

```c
(physical_address & (PMM_PAGE_SIZE - 1)) == 0
```

前提是 `PMM_PAGE_SIZE` 确实为 2 的幂。

### 10.3 `base + length`

验证 `[base, base + length)` 前，必须先排除加法 overflow。否则一个回绕后的 `end` 可能让错误范围通过边界检查。

## 11. 宏、`enum` 和常量

预处理宏只是编译前的文本替换：

```c
#define PMM_PAGE_SIZE UINT64_C(4096)
#define PAGE_FAULT_WRITE (UINT64_C(1) << 1)
```

带表达式的宏要给整体和参数加括号，避免优先级改变含义：

```c
#define ALIGN_DOWN(value, alignment) ((value) & ~((alignment) - 1))
```

宏参数可能被展开多次，所以不要把有副作用的表达式随意传给复杂宏：

```c
/* 如果宏使用 value 两次，index++ 可能执行两次。 */
SOME_MACRO(index++);
```

一组具名整数常量也可以使用 `enum`。但硬件寄存器的 64-bit mask 是否能被 `enum` 精确表达受实现影响，本课程对此仍优先使用带 `UINT64_C` 的宏。

## 12. GCC attributes：不是 ISO C 语法

Limine request、IDT 和底层入口会出现 GCC 扩展：

```c
__attribute__((used, section(".limine_requests")))
static volatile struct limine_memmap_request memory_map_request = {
    /* ... */
};
```

本课程常见属性：

| 属性 | 作用 | 不能证明什么 |
| --- | --- | --- |
| `used` | 即使普通 C 引用不可见，也要求编译器发出该对象或函数 | linker 一定保留；仍要看 linker script / `KEEP` / GC |
| `section("name")` | 把对象或函数放进指定 input section | 最终 VMA、权限或是否被加载；这些由 linker 和 ELF 决定 |
| `packed` | 尽量去掉结构体成员间 padding | 未对齐访问一定安全或高效 |
| `aligned(n)` | 请求至少 `n` bytes 对齐 | 自动建立 page mapping |
| `noreturn` | 告诉编译器函数不会正常返回 | 函数一定会 halt；实现仍须真正不返回 |

属性影响 compiler/linker contract。遇到它们时，除了读 C 源码，还应通过 `readelf`、`nm`、`objdump` 或运行时检查验证最终产物。

## 13. Undefined behavior 与 kernel 中的常见误区

kernel 有 ring 0 权限，不代表 C 的 undefined behavior 消失。常见问题包括：

- 数组越界或越过一个 frame；
- 解引用无 mapping、错误权限或未满足对齐要求的指针；
- 有符号整数溢出；
- 移位量大于等于类型宽度；
- 使用未初始化的自动变量；
- 函数声明与定义类型不一致；
- 把并发共享数据只标为 `volatile`；
- 违反编译器 aliasing 假设；
- inline assembly 没声明真实的输入、输出或 clobber。

这类错误的危险之处是：它们不一定立即触发 CPU exception。优化器可能重排或删除代码，错误也可能只是静默破坏别的内核数据。

## 14. 看一段内核 C 时的检查顺序

遇到不熟悉的代码，按下面顺序拆解：

1. 函数输入、直接返回值和 output parameter 分别是什么？
2. 每个整数是普通数值、长度、bit mask、PA 还是 VA？
3. 每个指针指向什么对象？当前页表为什么保证它可访问？
4. `sizeof` 算的是一个元素、整个数组，还是已经退化后的 pointer？
5. 循环使用什么半开区间？最后一次访问落在哪个 byte？
6. 加法、乘法和移位是否可能 overflow 或越界？
7. `const`、`volatile`、`static` 或 attribute 在约束谁？
8. 失败时返回什么，输出对象是否保持可预测状态？
9. 哪个结论能通过编译器告警、ELF 工具、QEMU 输出或异常现场验证？

## 15. 权威参考

- [C11 committee draft N1570](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf)：语言、freestanding/hosted environment 与标准头的规范来源。
- [GCC：Language Standards Supported by GCC](https://gcc.gnu.org/onlinedocs/gcc/Standards.html)：GCC 对 C 标准与 hosted/freestanding 环境的说明。
- [GCC：Variable Attributes](https://gcc.gnu.org/onlinedocs/gcc/Variable-Attributes.html)：`used`、`section`、`aligned` 等对象属性。
- [GCC：Function Attributes](https://gcc.gnu.org/onlinedocs/gcc/Function-Attributes.html)：`noreturn`、函数 `section` 等函数属性。
- 本仓库的 `Makefile`：本课程实际使用的 compiler flags 才是当前构建合同。

不需要从头背完。第一次遇到语法时找到对应小节，用当前源码和机器证据验证一次即可。
