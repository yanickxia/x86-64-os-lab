import type { Metadata } from "next";
import { MarkdownContent } from "../components";
import { course } from "../../lib/course";

export const metadata: Metadata = {
  title: "路线图",
  description: "从启动到用户态、调度与文件系统的完整 x86-64 操作系统学习路线。",
};

export default function RoadmapPage() {
  return (
    <main className="document-page shell">
      <header className="page-header page-header--compact">
        <p className="kicker">20—24 WEEKS · SYSTEM MAP</p>
        <h1>课程路线图</h1>
        <p>理论、实验与权威手册只服务于同一条实现主线。</p>
      </header>
      <article className="document-card">
        <MarkdownContent markdown={course.roadmap} />
      </article>
    </main>
  );
}
