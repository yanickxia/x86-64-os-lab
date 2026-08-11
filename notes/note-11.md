# 第 11 课学习记录

日期：2026.08.09

> 填写时机：先读完 long-mode 激活正文和红灯机制说明，再在第一次运行 `make check-long-mode` 前完成计算。

## 实验前计算

1. `CR4.PAE` 的 bit 与掩码： Bit5， 掩码是 1 << 5 = 0x00000020
2. PML4 的物理地址与 CR3 期望值： PML4 的物理地址是 0x00001000， CR3的期望值就 0x1000
3. `IA32_EFER` 编号、`LME/LMA` 的 bit 与掩码： IA32_EFER 是 Bit8， 掩码是 1 << 8 = 0x000000008，LME/LMA 是 Bit10    ， 掩码是 1 << 10 = 0x00000400
4. 设置 PG 后的 CR0：0x80000011
5. 64 位 code descriptor 的 index、TI、RPL 与 selector：index = 3，TI = 2，RPL = 0，selector = 0x18
6. 为什么 descriptor 必须 `L=1, D=0`：L=1 表示 64 位模式，D=0 表示 32 位模式
7. far jump 的 offset、selector 与 7 个机器码字节：32 位 far jump 的目标是 selector 0x18、offset 0x00007d30
8. 绿灯时 `CR0/CR3/CR4/EFER/CS` 的完整期望值：CR0 = 0x80000011，CR3 = 0x1000，CR4 = 0x00000000，EFER = 0x00000000，CS = 0x18

### 实验前计算复盘

保留上面的原始计算作为学习记录；实验后修正如下：

1. `IA32_EFER` 是编号为 `0xc0000080` 的完整 64 位 MSR，不是 bit 8。`LME` 才是其中的 bit 8，掩码为 `0x00000100`；`LMA` 是 bit 10，掩码为 `0x00000400`。
2. 64 位 code descriptor 的 index 是 3，`TI=0` 表示使用 GDT，`RPL=0`，所以 selector 是 `(3 << 3) | 0 | 0 = 0x18`。
3. `L=1` 选择 64 位代码；此时 `D/B` 必须为 0。`D=1` 只有在 `L=0` 时才表示 32 位默认操作数和地址宽度，不能把 `D=0` 本身理解成“32 位模式”。
4. 32 位 far jump 的 offset 是 `0x00007d30`，selector 是 `0x0018`，7 个机器码字节为 `EA 30 7D 00 00 18 00`。
5. 绿灯的完整期望值是 `CR0=0x80000011`、`CR3=0x0000000000001000`、`CR4=0x00000020`、`EFER=0x0000000000000500`、`CS=0x0018 CS64`。

## 红灯

- debug console 输出：debug console check passed: received 'HelloPTL' from I/O port 0xe9
- `make check-long-mode` 原始失败输出：
    ```
    long-mode check: expected CR0.PG=1, CR3=0x1000, CR4.PAE=1, EFER.LME=LMA=1, CS=0x0018 CS64
    long-mode check: CR0=00000011 CR2=00000000 CR3=00000000 CR4=00000000
    long-mode check: CS =0008 00000000 ffffffff 00cf9a00 DPL=0 CS32 [-R-]
    long-mode check: EFER=0000000000000000
    make: *** [check-long-mode] Error 1
    ```
- 红灯时的 `CR0/CR3/CR4`：CR0=00000011，CR3=00000000，CR4=00000000
- 红灯时的 `EFER`：EFER=0000000000000000
- 红灯时的 `CS` 与解码模式：CS=0008 ... CS32
- 为什么输出 `HelloPTL` 仍不能证明进入 long mode：输出字符只能证明控制流到过某段代码，不能证明 CPU 模式。

## 我的实现

```asm
; 记录 CR4.PAE → CR3 → EFER.LME → CR0.PG → far jump
enable_long_mode:
    ; Enable CR4.PAE.
    mov eax, cr4
    or eax, CR4_PAE
    mov cr4, eax

    ; CR3
    mov eax, PML4_ADDR
    mov cr3, eax

    ; EFER.LME
    mov ecx, IA32_EFER_MSR
    rdmsr
    or eax, EFER_LME
    wrmsr

    ; CR0.PG
    mov eax, cr0
    or eax, CR0_PG
    mov cr0, eax

    ; far jump 序列
    jmp CODE64_SELECTOR:long_mode_entry
```

## 绿灯原始观察

- `make check-long-mode`：
    ```
    boot sector check passed: 512 bytes, signature 55aa
    000001f0: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 55 aa  ..............U.
    long-mode check passed: CPU is executing 64-bit code
    long-mode state: CR0=80000011 CR2=0000000000000000 CR3=0000000000001000 CR4=00000020
    long-mode state: CS =0018 0000000000000000 ffffffff 00af9a00 DPL=0 CS64 [-R-]
    long-mode state: EFER=0000000000000500
    ```
- debug console 输出：debug console check passed: received 'HelloPTL' from I/O port 0xe9
- 绿灯时的 `CR0/CR3/CR4`：80000011 0000000000001000 00000020
- 绿灯时的 `EFER`：0000000000000500
- 绿灯时的 `CS` 与解码模式：0018 CS64
- 绿灯后 PML4[0]、PDPT[0]、PD[0] 的值：0x0000000000002023, 0x0000000000003023,0x00000000000000a3
- 32 位切换序列的反汇编与机器码：
  ```
    == 32-bit long-mode switch (0x7cf0-0x7d20) ==
    00007CF0  0F20E0                            mov eax,cr4
    00007CF3  83C820                            or eax,0x20
    00007CF6  0F22E0                            mov cr4,eax
    00007CF9  B800100000                        mov eax,0x1000
    00007CFE  0F22D8                            mov cr3,eax
    00007D01  B9800000C0                        mov ecx,0xc0000080
    00007D06  0F32                              rdmsr
    00007D08  0D00010000                        or eax,0x100
    00007D0D  0F30                              wrmsr
    00007D0F  0F20C0                            mov eax,cr0
    00007D12  0D00000080                        or eax,0x80000000
    00007D17  0F22C0                            mov cr0,eax
    00007D1A  EA307D00001800                    jmp word 0x18:dword 0x7d30
  ```
- 64 位入口的反汇编与机器码：
    ```
    00007D30  B04C  mov al,0x4c
    00007D32  E6E9  out byte 0xe9,al
    00007D34  EBFE  jmp 0x7d34
    ```

## 我的解释

1. 为什么需要 PAE：CR4.PAE=1 告诉 CPU：打开分页时要按 PAE/IA-32e 所需的 64 位 entry 格式解释页表，而不是旧式 32 位两级页表。
2. CR3 与 PML4[0] 的区别：CR3 保存 PML4 根表所在的物理地址 `0x1000`。CPU 到物理地址 `0x1000` 读取 PML4[0]；该 entry 的值 `0x2003` 再表示下一级 PDPT 位于物理地址 `0x2000`，并携带 `P/RW` flags。
3. 为什么按这个顺序设置控制状态：页表必须先在 RAM 中有效，随后 `CR4.PAE=1` 选择 IA-32e 所需的 64 位 entry 格式，CR3 指定 PML4 根，`EFER.LME=1` 武装 long mode。最后设置 `CR0.PG` 才开始 page-table walk 并令 CPU 自动设置 LMA；far jump 再加载 `L=1` 的 code descriptor，使当前指令流从 compatibility mode 进入 64-bit mode。若提前打开 PG，CPU 会按尚未准备好的格式或根表取指并产生 fault。
4. LME 与 LMA 的区别：LME 是 EFER bit 8，由软件写入，表示满足其他条件时允许激活 long mode；LMA 是 EFER bit 10，由 CPU 管理，表示 IA-32e mode 已经 active。执行 `WRMSR` 后先得到 `LME=1、LMA=0`；在 PAE、CR3 和页表均有效时打开 `CR0.PG`，CPU 才自动令 LMA=1，因此最终 EFER 为 `0x500`。
5. `RDMSR/WRMSR` 的寄存器约定：ECX 保存 MSR 编号；`RDMSR` 把所选 64 位 MSR 读入 `EDX:EAX`，EDX 是高 32 位、EAX 是低 32 位。本课只在 EAX 中 OR `EFER_LME`，同时保留 EDX 和其他已有位；`WRMSR` 再把完整的 `EDX:EAX` 写回 ECX 选择的 IA32_EFER。
6. 为什么打开 PG 后还要 far jump：打开 PG 会激活 IA-32e mode，但当前 CS 仍缓存 `L=0, D=1` 的 32 位 descriptor，因此处理器暂时处于 compatibility mode。far jump 加载 selector `0x18` 对应的 `L=1, D=0` descriptor，更新 CS 的可见 selector 与隐藏属性，CPU 才按 64 位规则解码后续指令。
7. `bits 64` 为什么不是模式切换指令：bits 64 只告诉 NASM 后面的代码应按 64 位默认规则编码，不生成机器码。
8. 恒等映射在切换瞬间保护了什么：低 2 MiB 恒等映射覆盖当前切换代码、far jump 的目标、GDT 和 `0x90000` 栈，使打开分页后的 linear address 仍落到同数值 physical address，无需同时搬代码、栈或重算跳转目标。
9. page-table walk 为什么会设置 Accessed 位：CPU 真正使用各级 entry 完成地址翻译后，会自动设置 Accessed（A，bit 5）记录路径已被访问。因此三个值分别由 `0x2003/0x3003/0x0083` OR `0x20` 变为 `0x2023/0x3023/0x00a3`；下级表或 page frame 的地址部分以及原有 `P/RW/PS` flags 都没有改变。
10. 相同输出为什么不能证明模式：输出字符只能证明控制流到过某段代码，不能证明 CPU 模式
11. 为什么 64 位内存管理主要依靠 paging：在 64-bit mode 中，普通 `CS/DS/ES/SS` 的 base 被视为 0、limit 基本不参与地址检查，传统 segmentation 被弱化；paging 则是进入 long mode 的强制条件。操作系统通过页表把 linear/virtual page 映射到 physical frame，并逐页实现权限、隔离、稀疏分配、共享和 copy-on-write，因此它成为主要内存管理机制。

## 仍然不清楚的问题

-
