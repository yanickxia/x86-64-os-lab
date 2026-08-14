import type { Metadata } from "next";
import { MarkdownContent } from "../../components";
import { course } from "../../../lib/course";

export const metadata: Metadata = {
  title: "Freestanding C 参考",
  description: "课程内核主线需要的 freestanding C、指针、位运算、边界检查与 GCC attributes 速查。",
};

export default function CReferencePage() {
  return (
    <main className="document-page shell">
      <header className="page-header page-header--compact">
        <p className="kicker">REFERENCE · KERNEL C</p>
        <h1>C 语言基础参考</h1>
        <p>围绕本课程的 freestanding kernel C；遇到新语法时回到这里确认机器含义。</p>
      </header>
      <article className="document-card">
        <MarkdownContent markdown={course.cReference} />
      </article>
    </main>
  );
}
