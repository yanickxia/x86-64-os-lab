import type { Metadata } from "next";
import { LessonSectionList } from "../components";
import { course, getCourseSections } from "../../lib/course";

export const metadata: Metadata = {
  title: "课程",
  description: "x86-64 操作系统实验课程索引。",
};

export default function LessonsPage() {
  const sections = getCourseSections();

  return (
    <main className="page-shell shell">
      <header className="page-header">
        <p className="kicker">COURSE INDEX · 00—{course.lessons.at(-1)?.id}</p>
        <h1>沿着控制流，<br />逐层理解机器。</h1>
        <p>课程按五个大阶段组织。展开当前阶段继续学习，或按课号范围快速定位已经完成的内容。</p>
      </header>

      <LessonSectionList sections={sections} index />
    </main>
  );
}
