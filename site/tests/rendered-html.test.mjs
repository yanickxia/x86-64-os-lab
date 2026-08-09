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

test("renders a finished course homepage", async () => {
  const response = await render("/");
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /从复位向量/);
  assert.match(html, /BOOT TRACE/);
  assert.match(html, /<strong>10<\/strong><span>节已完成/);
  assert.match(html, /32 位保护模式里程碑已完成/);
  assert.doesNotMatch(html, /下一步：/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|Your site is taking shape/);
});

test("renders lesson, roadmap, and reference routes", async () => {
  const routes = [
    ["/lessons", /沿着控制流/],
    ["/lessons/lesson-05", /call.*返回地址.*ret/is],
    ["/lessons/lesson-07", /A20.*1 MiB/is],
    ["/lessons/lesson-08", /GDT.*LGDT.*GDTR/is],
    ["/lessons/lesson-09", /CR0\.PE.*far jump.*bits 32/is],
    ["/roadmap", /20-24 周/],
    ["/reference", /RAX.*EAX.*AX.*AH.*AL/is],
  ];

  for (const [pathname, expected] of routes) {
    const response = await render(pathname);
    assert.equal(response.status, 200, pathname);
    assert.match(await response.text(), expected, pathname);
  }
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
  assert.match(generated, /第 0 课：先认识实验机器/);
  assert.match(generated, /第 6 课：从内存遍历 NUL 结尾的字符串/);
});
