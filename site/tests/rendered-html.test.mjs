import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function getWorker() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}-${Math.random()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker;
}

async function render(pathname) {
  const worker = await getWorker();
  return worker.fetch(
    new Request(`http://localhost${pathname}`, {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("renders the current course homepage", async () => {
  const response = await render("/");
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /从复位向量/);
  assert.match(html, /BOOT TRACE/);
  assert.match(html, /<strong>32<\/strong><span>节已完成/);
  assert.match(html, /PML4 ROOT/);
  assert.match(html, /CS64 ENTRY/);
  assert.match(html, /共 (?:<!-- -->)?32(?:<!-- -->)? 节/);
  assert.match(html, /MILESTONE REACHED/);
  assert.match(html, /第一次缺页恢复已经闭环/);
  assert.match(html, /#PF → MAP → INVLPG → RETRY/);
  assert.match(html, /href="\/lessons\/lesson-12"/);
  assert.match(html, /href="\/lessons\/lesson-13"/);
  assert.match(html, /href="\/lessons\/lesson-14"/);
  assert.match(html, /href="\/lessons\/lesson-15"/);
  assert.match(html, /href="\/lessons\/lesson-16"/);
  assert.match(html, /href="\/lessons\/lesson-17"/);
  assert.match(html, /href="\/lessons\/lesson-18"/);
  assert.match(html, /href="\/lessons\/lesson-19"/);
  assert.match(html, /href="\/lessons\/lesson-20"/);
  assert.match(html, /href="\/lessons\/lesson-21"/);
  assert.match(html, /href="\/lessons\/lesson-22"/);
  assert.match(html, /href="\/lessons\/lesson-23"/);
  assert.match(html, /href="\/lessons\/lesson-24"/);
  assert.match(html, /href="\/lessons\/lesson-25"/);
  assert.match(html, /href="\/lessons\/lesson-26"/);
  assert.match(html, /href="\/lessons\/lesson-27"/);
  assert.match(html, /href="\/lessons\/lesson-28"/);
  assert.match(html, /href="\/lessons\/lesson-29"/);
  assert.match(html, /href="\/lessons\/lesson-30"/);
  assert.match(html, /href="\/lessons\/lesson-31"/);
  assert.match(html, /href="\/reference"/);
  assert.match(html, /href="\/reference\/c"/);
  assert.match(html, /SECTION (?:<!-- -->)?01.*SECTION (?:<!-- -->)?02.*SECTION (?:<!-- -->)?03.*SECTION (?:<!-- -->)?04.*SECTION (?:<!-- -->)?05.*SECTION (?:<!-- -->)?06/s);
  assert.match(html, /从复位到程序控制流.*进入 x86-64 Long Mode.*加载、交接与 ELF.*启动复盘与理解检验.*C 内核与 Bootloader 毕业.*Limine 与内核主线/s);
  assert.equal((html.match(/<details[^>]+class="lesson-section/g) ?? []).length, 6);
  assert.match(html, /<details[^>]+class="lesson-section is-current"[^>]+open=""/);
  assert.doesNotMatch(html, /NEXT CHECKPOINT/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Your site is taking shape/);
});

test("renders lesson, roadmap, and reference routes", async () => {
  const routes = [
    ["/lessons", /沿着控制流/],
    ["/lessons/lesson-05", /call.*返回地址.*ret/is],
    ["/lessons/lesson-07", /A20.*1 MiB/is],
    ["/lessons/lesson-08", /GDT.*LGDT.*GDTR/is],
    ["/lessons/lesson-09", /CR0\.PE.*far jump.*bits 32/is],
    ["/lessons/lesson-10", /PML4.*effective address.*flat segmentation.*CR3.*TLB/is],
    ["/lessons/lesson-11", /CR4\.PAE.*CR3.*0xc0000080.*EDX:EAX.*LME.*LMA.*CR0\.PG.*CS64/is],
    ["/lessons/lesson-12", /INT 13h.*ES:BX.*0x10000.*sector 2/is],
    ["/lessons/lesson-13", /JMP rel32.*绝对间接跳转.*CS64/is],
    ["/lessons/lesson-14", /ELF64.*linker script.*location counter.*VMA.*objcopy/is],
    ["/lessons/lesson-15", /恒等映射.*triple fault.*IDT.*OSTEP/is],
    ["/lessons/lesson-15", /完整路径.*交给 C 前.*FFFF:0010.*空指针解引用通常不会触发.*#PF/is],
    ["/lessons/lesson-16", /x86-64.*RISC-V.*AArch64.*CR3.*satp.*VBAR_EL1.*内存模型/is],
    ["/lessons/lesson-17", /100 分.*判断并解释.*因果链与诊断.*A20.*B6/is],
    ["/lessons/lesson-18", /freestanding.*System V x86-64 ABI.*kernel_main.*debug_putc.*HelloPTLKC/is],
    ["/lessons/lesson-19", /UD2.*vector 6.*exception_frame.*IRETQ.*HelloPTLKCUR/is],
    ["/lessons/lesson-20", /自己的 bootloader.*4 个扇区.*LOAD4SEC.*0x107f8.*第 25 课/is],
    ["/lessons/lesson-21", /stage 1.*stage 2.*0x8000.*STAGE2OK.*CALL.*RET/is],
    ["/lessons/lesson-22", /E820.*boot_info.*0x5000.*RDI.*E820COK/is],
    ["/lessons/lesson-23", /PT_LOAD.*p_filesz.*p_memsz.*\.bss.*ELF64OK.*kernel_stack/is],
    ["/lessons/lesson-24", /毕业审计.*stage 1.*stage 2.*boot_info.*PT_LOAD.*Limine/is],
    ["/lessons/lesson-25", /Limine bootloader.*boot protocol.*request.*response.*RDI.*memory map.*allocator.*cannot open source file.*make limine-deps.*inspect-limine-api.*提示 1/is],
    ["/lessons/lesson-26", /physical frame.*PMM.*VMM.*BOOTLOADER_RECLAIMABLE.*ownership.*PA 0.*pmm_init.*pmm_alloc_page/is],
    ["/lessons/lesson-27", /Higher Half Direct Map.*VA = HHDM offset \+ PA.*aliasing.*不是 512 页.*4096 bytes \/ 8 bytes.*2\^9.*整套页表不是只有一个页.*PML4.*PDPT.*PD page.*PT page.*512 words.*CR3.*预测修订.*原预测.*真实结果.*错误原因/is],
    ["/lessons/lesson-28", /Page Fault.*vector 14.*CR2.*error code.*saved RIP.*0x2.*non-present.*supervisor.*IRETQ.*page_fault_decode/is],
    ["/lessons/lesson-28", /不再换一种措辞重复作答.*地址空间 policy.*TLB invalidation.*预测修订/is],
    ["/lessons/lesson-29", /PML4 → PDPT → PD → PT → frame/],
    ["/lessons/lesson-29", /entry 中放 PA，不放 HHDM VA/],
    ["/lessons/lesson-29", /indices: 0x24 \/ 0xd1 \/ 0xb3 \/ 0x189/],
    ["/lessons/lesson-29", /entries: 0x2003 → 0x3003 → 0x4003 → 0x0003/],
    ["/lessons/lesson-29", /VMM:ROOT:INACTIVE.*唯一新增的收束题/is],
    ["/lessons/lesson-30", /kernel-owned PML4.*shallow copy.*borrowed subtrees.*MOV CR3/is],
    ["/lessons/lesson-30", /旧 PML4（Limine 提供，CPU 当前使用）.*新 PML4（kernel-owned，CPU 尚未使用）.*复制其余 511 项/is],
    ["/lessons/lesson-30", /destination.*新 kernel-owned PML4.*source.*旧 PML4.*preserved_index.*0x24/is],
    ["/lessons/lesson-30", /不是本课先修知识，也不会出现在必答题中/is],
    ["/lessons/lesson-30", /0x24.*0x1ff.*0x100.*0x30c0ffee30c0ffee.*PF:DIAG:OK/is],
    ["/lessons/lesson-30", /不预测 old.*CR3.*精确.*RSP.*唯一新增的解释题/is],
    ["/lessons/lesson-31", /demand paging.*pre-reserved frame.*producer.*consumer.*observer.*INVLPG.*IRETQ/is],
    ["/lessons/lesson-31", /UD2 仍然非法.*store 本身合法.*保留 RIP.*重新执行/is],
    ["/lessons/lesson-31", /只回答这一题.*不需要预测 PA、RIP 或完整日志.*唯一新增的解释题/is],
    ["/lessons/lesson-31", /课中追问汇总.*faulting address.*向下对齐.*0x18a.*vmm_resolve_demand_write.*失败分支/is],
    ["/roadmap", /20-24 周/],
    ["/reference", /RAX.*EAX.*AX.*AH.*AL/is],
    ["/reference/c", /freestanding.*uintptr_t.*sizeof.*const.*volatile.*output parameter.*GCC attributes/is],
  ];

  for (const [pathname, expected] of routes) {
    const response = await render(pathname);
    assert.equal(response.status, 200, pathname);
    assert.match(await response.text(), expected, pathname);
  }

  const indexResponse = await render("/lessons");
  const indexHtml = await indexResponse.text();
  assert.equal((indexHtml.match(/<details[^>]+class="lesson-section/g) ?? []).length, 6);
  assert.match(indexHtml, /展开当前阶段继续学习.*按课号范围快速定位/s);

  const examResponse = await render("/lessons/lesson-17");
  const examHtml = await examResponse.text();
  assert.match(examHtml, /<strong>A1\.<\/strong>.*<strong>A10\.<\/strong>.*<strong>A20\.<\/strong>/s);
  assert.doesNotMatch(examHtml, /<h2[^>]*>C\.|<h2[^>]*>D\./);
  assert.doesNotMatch(examHtml, /标准答案|参考答案/);
});

test("keeps Markdown as the canonical source", async () => {
  const generator = await readFile(
    new URL("../scripts/sync-content.mjs", import.meta.url),
    "utf8",
  );
  const generated = await readFile(
    new URL("../content/course.generated.ts", import.meta.url),
    "utf8",
  );

  assert.match(generator, /docs\/\$\{meta\.slug\}\.md/);
  assert.match(generator, /notes\/note-\$\{meta\.id\}\.md/);
  assert.match(generator, /docs\/reference\/assembly-basics\.md/);
  assert.match(generator, /docs\/reference\/c-basics\.md/);
  assert.match(generated, /第 0 课：先认识实验机器/);
  assert.match(generated, /第 6 课：从内存遍历 NUL 结尾的字符串/);
  assert.match(generated, /Freestanding C 与内核代码参考/);
});
