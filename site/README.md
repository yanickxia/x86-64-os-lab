# x86-64 OS Field Notes

这是 `x86-64-os-lab` 的多页面课程回顾站点。课程 Markdown 仍是唯一内容源，站点不会复制出另一套需要手工维护的正文。

## 本地预览

要求 Node.js `>=22.13.0`。

```bash
cd site
npm install
npm run dev
```

然后访问 <http://localhost:3000>。

## 页面

- `/`：学习进度、启动链路和下一课
- `/lessons`：课程目录
- `/lessons/lesson-00` 至当前最新课程：课程正文与个人答案
- `/roadmap`：完整学习路线
- `/reference`：NASM 与 x86 汇编速查

## 内容同步

运行 `npm run dev` 或 `npm run build` 前，站点会自动执行 `scripts/sync-content.mjs`，读取：

- `../docs/lesson-*.md`
- `../notes/lesson-*.md`
- `../docs/roadmap.md`
- `../docs/reference/assembly-basics.md`

新增课程后，需要在 `scripts/sync-content.mjs` 的课程元数据中加入一项；正文和笔记依旧直接维护在原 Markdown 文件中。

## 验证

```bash
npm test
```

该命令会重新同步内容、构建站点，并检查首页、课程、路线图和参考页面的渲染结果。
