import type { Metadata } from "next";
import { MarkdownContent } from "../components";
import { course } from "../../lib/course";

export const metadata: Metadata = {
  title: "NASM 与寄存器参考",
  description: "课程前几阶段需要的 NASM 语法、x86 寄存器与 I/O 指令速查。",
};

export default function ReferencePage() {
  return (
    <main className="document-page shell">
      <header className="page-header page-header--compact">
        <p className="kicker">REFERENCE · KEEP NEARBY</p>
        <h1>汇编基础参考</h1>
        <p>不要求一次背完；首次遇到语法时，回到这里确认。</p>
      </header>
      <article className="document-card">
        <MarkdownContent markdown={course.reference} />
      </article>
    </main>
  );
}
