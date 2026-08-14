# x86-64 OS Lab

这是一个从零实现 x86-64 教学操作系统的长期学习仓库。目标不是尽快拼出一个能启动的镜像，而是能解释、实现并调试从 CPU 复位到用户进程运行的完整路径。

## 两条实现线

1. 手工启动线：亲手走一遍 BIOS、16 位实模式、保护模式、分页和长模式，建立 x86 的历史包袱与机器模型。
2. Bootloader 毕业阶段：已经完成多扇区、stage 2、E820/boot info、ELF/.bss/栈与 ABI handoff，并完成逐项取证。
3. 内核主线：从第 25 课起把自制 handoff 与 Limine protocol 对照，使用成熟启动环境，把精力放在内存、进程、系统调用、并发和文件系统。

`../impl-x64-os` 是旧实现和考古材料，不是本课程的起始代码。它的现有修改会原样保留。

## 学习规则

- 每课只引入一个主要机制。
- 每课在练习前列出先修知识，并讲清本课新增的最小语法与机器模型。
- 首次出现的汇编、C 语言或工具语法必须给出可运行示例和权威参考，不能把必要知识藏在练习里。
- 写代码前先预测机器状态和输出。
- 每个结论都尽量用 QEMU、GDB、反汇编或测试证明。
- 我先给问题和最小提示；遇到阻塞再逐级增加提示。
- 每个里程碑结束时，用自己的话解释控制流和关键不变量，并留下一个干净提交。

## 从这里开始

```sh
source ~/.zshrc
cd /Users/yanick/codes/mine/operating-system/x86-64-os-lab
make check-tools
```

然后阅读 [第 0 课](docs/lesson-00.md)，并把答案写入 [学习记录](notes/note-00.md)。整体路线见 [课程路线图](docs/roadmap.md)。

当前已完成 [第 28 课：让 Page Fault 说清楚哪里错了](docs/lesson-28.md)：vector 14 已能进入 C，并用 `CR2 + error code + saved RIP` 留下可读证据。下一阶段会把 PMM frame 组织成 kernel-owned page tables。

多页面课程站由 GitHub Actions 自动部署到 [os-lab.pages.yanick.site](https://os-lab.pages.yanick.site/)。本地仍可在 `site/` 中运行 `npm run dev` 预览。

常用基础参考：[NASM 与 x86 寄存器入门](docs/reference/assembly-basics.md)、[Freestanding C 与内核代码](docs/reference/c-basics.md)。



## 参考资料
- [MIT 6.828 课程](https://pdos.csail.mit.edu/6.828/2018/labs/)
- [OSDev Wiki](https://wiki.osdev.org/)
- [JOS 课程](https://github.com/phlalx/jos)
- [Awsome Courses](https://github.com/forthespada/Awsome-Courses)
- [OS](https://github.com/aminkhani/OS)
- [os-tutorial](https://github.com/cfenollosa/os-tutorial)
- [os-dev](https://github.com/cpey/os-dev)
- [riscv](https://pdos.csail.mit.edu/6.1810/2025/xv6/book-riscv-rev5.pdf)
- [Operating Systems: Three Easy Pieces](https://pages.cs.wisc.edu/~remzi/OSTEP/)
- [MIT 6.828 课程](https://pdos.csail.mit.edu/6.828/2018/labs/)
