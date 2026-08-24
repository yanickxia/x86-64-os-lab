# x86-64 OS Lab

这是一个从零实现 x86-64 教学操作系统的长期学习仓库。目标不是尽快拼出一个能启动的镜像，而是能解释、实现并调试从 CPU 复位到用户进程运行的完整路径。

## 两条实现线

1. 手工启动线：亲手走一遍 BIOS、16 位实模式、保护模式、分页和长模式，建立 x86 的历史包袱与机器模型。
2. Bootloader 毕业阶段：已经完成多扇区、stage 2、E820/boot info、ELF/.bss/栈与 ABI handoff，并完成逐项取证。
3. 内核主线：从第 25 课起把自制 handoff 与 Limine protocol 对照，使用成熟启动环境，把精力放在内存、进程、系统调用、并发和文件系统。

`../impl-x64-os` 是旧实现和考古材料，不是本课程的起始代码。它的现有修改会原样保留。

## 学习规则

- 启动基础可以按单一机器机制拆分；进入 OS 主线后，每章围绕一个完整能力组合 2–4 个强相关机制。
- 整合章只保留一个贯穿实验和最多 2–3 个必答项，预计 90–150 分钟；超过这个负担才继续拆章。
- 每章在练习前列出先修知识，并讲清新增语法、状态边界与各机制如何协作。
- 首次出现的汇编、C 语言或工具语法必须给出可运行示例和权威参考，不能把必要知识藏在练习里。
- 写代码前先预测机器状态和输出。
- 每个结论都尽量用 QEMU、GDB、反汇编或测试证明。
- 课中在聊天侧栏或代码审阅里产生的实质性追问，会在结课时汇总进对应 `notes/note-NN.md`；状态确认、格式问题和重复提问不收录。
- 我先给问题和最小提示；遇到阻塞再逐级增加提示。
- 每个里程碑结束时，用自己的话解释控制流和关键不变量，并留下一个干净提交。

## 从这里开始

```sh
source ~/.zshrc
cd /Users/yanick/codes/mine/operating-system/x86-64-os-lab
make check-tools
```

然后阅读 [第 0 课](docs/lesson-00.md)，并把答案写入 [学习记录](notes/note-00.md)。整体路线见 [课程路线图](docs/roadmap.md)。

当前已完成 [第 32 课：让内核自己找到 leaf PTE](docs/lesson-32.md)：kernel 能从 active root PA 与任意 VA 出发，
经 HHDM 沿已有 parent path 定位 mapped 或 empty leaf slot。
下一步是 [第 33 课：建立 4 KiB 映射的完整生命周期](docs/lesson-33.md)，
把 PMM、HHDM 与 walker 收敛成 create、reuse、unmap 和 TLB/ownership 边界。

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
