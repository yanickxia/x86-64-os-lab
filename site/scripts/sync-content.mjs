import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const courseRoot = path.resolve(siteRoot, "..");
const generatedDir = path.join(siteRoot, "content");

const lessonMeta = [
  {
    id: "00",
    slug: "lesson-00",
    phase: "实验环境",
    status: "completed",
    summary: "区分 Apple Silicon 宿主、x86-64 编译目标与 QEMU guest，建立可验证的交叉编译环境。",
    takeaway: "host ≠ target ≠ guest",
  },
  {
    id: "01",
    slug: "lesson-01",
    phase: "CPU 复位",
    status: "completed",
    summary: "暂停 CPU 的第一条指令，读取复位寄存器、复位向量和第一条 16 位远跳转。",
    takeaway: "0xfffffff0 → BIOS",
  },
  {
    id: "02",
    slug: "lesson-02",
    phase: "BIOS 启动",
    status: "completed",
    summary: "构造 512 字节启动扇区，用签名、内存比较和 GDB 证明 BIOS 的加载行为。",
    takeaway: "512 bytes · 55 aa · 0x7c00",
  },
  {
    id: "03",
    slug: "lesson-03",
    phase: "端口 I/O",
    status: "completed",
    summary: "使用真实的 x86 OUT 指令与 QEMU debug console 输出第一个可观察字符。",
    takeaway: "AL → port 0xe9",
  },
  {
    id: "04",
    slug: "lesson-04",
    phase: "实模式",
    status: "completed",
    summary: "建立 DS/ES/SS 与栈不变量，观察 PUSH 如何改变 SP 并写入低地址内存。",
    takeaway: "SS:SP · stack grows down",
  },
  {
    id: "05",
    slug: "lesson-05",
    phase: "函数调用",
    status: "completed",
    summary: "把字符输出封装为 putc，通过栈上的返回地址证明 CALL/RET 控制流。",
    takeaway: "call → return IP → ret",
  },
  {
    id: "06",
    slug: "lesson-06",
    phase: "内存与循环",
    status: "completed",
    summary: "从内存逐字节读取 NUL 结尾的字符串，用 ZF 和条件跳转控制循环。",
    takeaway: "DS:SI → TEST → JZ",
  },
  {
    id: "07",
    slug: "lesson-07",
    phase: "地址总线",
    status: "completed",
    summary: "理解 1 MiB 地址回绕，通过系统控制端口安全开启 A20 地址线。",
    takeaway: "port 0x92 · A20 · 1 MiB",
  },
  {
    id: "08",
    slug: "lesson-08",
    phase: "保护模式准备",
    status: "completed",
    summary: "构造 null、code、data 三项最小 GDT，并用 LGDT 装入 GDTR。",
    takeaway: "GDT · descriptor · LGDT",
  },
  {
    id: "09",
    slug: "lesson-09",
    phase: "保护模式",
    status: "completed",
    summary: "设置 CR0.PE，通过 far jump 重载 CS，并在 32 位入口建立数据段和栈。",
    takeaway: "CR0.PE · far jump · bits 32",
  },
  {
    id: "10",
    slug: "lesson-10",
    phase: "分页准备",
    status: "completed",
    summary: "构造 PML4、PDPT 和 PD，用 2 MiB large page 为 long mode 准备低地址恒等映射。",
    takeaway: "PML4 → PDPT → 2 MiB page",
  },
  {
    id: "11",
    slug: "lesson-11",
    phase: "长模式切换",
    status: "completed",
    summary: "启用 PAE，加载 CR3 与 EFER.LME，打开分页并通过 64 位代码段进入 long mode。",
    takeaway: "PAE · CR3 · EFER.LME · CR0.PG · CS64",
  },
  {
    id: "12",
    slug: "lesson-12",
    phase: "磁盘加载",
    status: "completed",
    summary: "用 BIOS INT 13h 把镜像第 2 个扇区读到物理地址 0x10000，为独立 64 位内核准备载荷。",
    takeaway: "INT 13h · CHS 0/0/2 · ES:BX",
  },
  {
    id: "13",
    slug: "lesson-13",
    phase: "控制权转移",
    status: "completed",
    summary: "在 long mode 中用绝对间接跳转把执行权交给 0x10000 的独立载荷，并用 RIP 证明 CPU 正在载荷里执行。",
    takeaway: "JMP r/m64 · RIP 0x1000e",
  },
  {
    id: "14",
    slug: "lesson-14",
    phase: "ELF 链接",
    status: "completed",
    summary: "把独立载荷构建成 ELF64 executable，用 linker script 让 entry、.text 与 symbols 匹配真实加载地址 0x10000。",
    takeaway: "ELF64 · linker script · VMA 0x10000",
  },
  {
    id: "15",
    slug: "lesson-15",
    phase: "阶段复盘",
    status: "completed",
    summary: "不引入新机制：把 reset、BIOS、模式切换、分页、ELF 载荷和 C 前缺口串成一条完整因果链。",
    takeaway: "启动全链路 · C 前状态",
  },
  {
    id: "16",
    slug: "lesson-16",
    phase: "架构对照",
    status: "completed",
    summary: "横向比较 x86-64、RV64 RISC-V 与 AArch64，分清 CPU 特有入口代码与操作系统共同抽象。",
    takeaway: "x86-64 ↔ RISC-V ↔ ARM64",
  },
  {
    id: "17",
    slug: "lesson-17",
    phase: "阶段考试",
    status: "completed",
    summary: "只用判断解释与因果诊断两部分，检验是否真正理解启动、地址转换和 C 前执行环境。",
    takeaway: "explain · trace · diagnose",
  },
  {
    id: "18",
    slug: "lesson-18",
    phase: "C 内核入口",
    status: "completed",
    summary: "让 64 位汇编入口按 SysV ABI 调用第一个 freestanding C 函数，并用真实输出验证跨语言边界。",
    takeaway: "ASM CALL → C → port 0xe9",
  },
  {
    id: "19",
    slug: "lesson-19",
    phase: "异常处理",
    status: "completed",
    summary: "安装最小 IDT，让 UD2 产生的 #UD 进入 C handler，修改异常帧后通过 IRETQ 恢复执行。",
    takeaway: "#UD → IDT → C → IRETQ",
  },
  {
    id: "20",
    slug: "lesson-20",
    phase: "Bootloader 完成",
    status: "completed",
    summary: "继续使用自己的 BIOS loader，把 4-sector 内核完整搬到 RAM，并用尾部标记证明加载长度合同。",
    takeaway: "4 sectors → 0x10000..0x107ff",
  },
  {
    id: "21",
    slug: "lesson-21",
    phase: "Bootloader 完成",
    status: "completed",
    summary: "让 stage 1 加载并调用独立 stage2.bin，用 RAM 握手区分“字节已加载”和“CPU 确实执行”。",
    takeaway: "stage 1 CALL → stage 2 RET",
  },
  {
    id: "22",
    slug: "lesson-22",
    phase: "Bootloader 完成",
    status: "completed",
    summary: "由 stage 2 查询 BIOS E820，发布带版本和边界的 boot_info，并通过 RDI 交给 64 位 C 内核。",
    takeaway: "E820 → boot_info → RDI → C",
  },
  {
    id: "23",
    slug: "lesson-23",
    phase: "Bootloader 完成",
    status: "completed",
    summary: "承接第 22 课，把 kernel 装载职责从 stage 1 迁入 stage 2：按 ELF PT_LOAD 复制 file bytes、清零 .bss，再进入 C。",
    takeaway: "PT_LOAD → .bss → stack → C",
  },
  {
    id: "24",
    slug: "lesson-24",
    phase: "Bootloader 毕业",
    status: "completed",
    summary: "不再增加启动机制：审计 stage 1、stage 2、boot_info、ELF、栈与 C handoff，明确成熟 loader 和后续 kernel 各自接手什么。",
    takeaway: "IMPLEMENTED ↔ DEFERRED ↔ KERNEL-OWNED",
  },
  {
    id: "25",
    slug: "lesson-25",
    phase: "Limine 换轨",
    status: "completed",
    summary: "先认识 Limine bootloader 与 boot protocol，再逐项映射自制 loader 的职责，最后让高半 C 内核消费 memory-map response。",
    takeaway: "REQUEST → RESPONSE → KERNEL",
  },
  {
    id: "26",
    slug: "lesson-26",
    phase: "物理内存管理",
    status: "completed",
    summary: "把 Limine 的只读 memory map 转成 kernel 自己的物理页 ownership 状态，用最小 allocator 发出两个不同的 4 KiB frame。",
    takeaway: "USABLE → FREE → KERNEL-OWNED",
  },
  {
    id: "27",
    slug: "lesson-27",
    phase: "内核内存访问",
    status: "completed",
    summary: "请求 Limine HHDM offset，把 PMM 返回的 PA 转成可解引用 VA，并用非零哨兵证明完整 4 KiB frame 已被清零。",
    takeaway: "VA = HHDM offset + PA",
  },
  {
    id: "28",
    slug: "lesson-28",
    phase: "异常诊断",
    status: "completed",
    summary: "在修改页表前安装 vector 14 安全网，用 CR2、error code 与 saved RIP 诊断一次可重复的 kernel page fault。",
    takeaway: "#PF → CR2 + ERROR + RIP",
  },
  {
    id: "29",
    slug: "lesson-29",
    phase: "虚拟内存",
    status: "completed",
    summary: "把四个 kernel-owned frames 连接成一条可检查的 PML4→PDPT→PD→PT 映射路径，暂不加载 CR3。",
    takeaway: "VA INDICES → TABLE PAs → LEAF PA",
  },
  {
    id: "30",
    slug: "lesson-30",
    phase: "虚拟内存",
    status: "completed",
    summary: "浅拷贝 active PML4 的 live entries、保留 custom mapping slot，再切换 CR3 并验证 code、stack、HHDM、alias 与 #PF 全部存活。",
    takeaway: "BORROW LIVE SUBTREES → LOAD CR3",
  },
  {
    id: "31",
    slug: "lesson-31",
    phase: "缺页恢复",
    status: "completed",
    summary: "让一次 non-present supervisor write 进入 #PF，发布预留 frame 的 PTE，并通过 INVLPG + IRETQ 重试原 store。",
    takeaway: "#PF → MAP → INVLPG → RETRY",
  },
  {
    id: "31.5",
    slug: "lesson-31.5",
    phase: "地址模型桥接",
    status: "completed",
    summary: "统一 PA、VA、physical frame、PMM、VMM、PTE 与 HHDM，并用一条具体四级路径解释 kernel 为什么还要 software walk。",
    takeaway: "PMM PA → HHDM VA → PTE → MMU",
  },
  {
    id: "32",
    slug: "lesson-32",
    phase: "虚拟内存",
    status: "completed",
    summary: "从 active root PA 与任意 VA 出发，经 HHDM 沿已有父级定位 mapped 或 empty leaf PTE，为通用 map/unmap 收敛接口。",
    takeaway: "ROOT PA → HHDM → LEAF PTE*",
  },
];

function titleFromMarkdown(markdown) {
  return markdown.match(/^#\s+(.+)$/m)?.[1] ?? "Untitled";
}

async function read(relativePath) {
  return readFile(path.join(courseRoot, relativePath), "utf8");
}

const lessons = await Promise.all(
  lessonMeta.map(async (meta) => {
    const markdown = await read(`docs/${meta.slug}.md`);
    const notes = await read(`notes/note-${meta.id}.md`);
    return {
      ...meta,
      title: titleFromMarkdown(markdown).replace(/`/g, ""),
      markdown,
      notes,
    };
  }),
);

const roadmap = await read("docs/roadmap.md");
const reference = await read("docs/reference/assembly-basics.md");
const cReference = await read("docs/reference/c-basics.md");

const course = {
  title: "x86-64 OS Field Notes",
  subtitle: "从 CPU 复位到自己的内核",
  completedCount: lessons.filter((lesson) => lesson.status === "completed").length,
  lessons,
  roadmap,
  reference,
  cReference,
};

await mkdir(generatedDir, { recursive: true });
await writeFile(
  path.join(generatedDir, "course.generated.ts"),
  `// Generated by scripts/sync-content.mjs. Do not edit by hand.\nexport const course = ${JSON.stringify(course, null, 2)} as const;\n`,
  "utf8",
);

console.log(`Synced ${lessons.length} lessons from ${courseRoot}`);
