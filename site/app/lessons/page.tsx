import type { Metadata } from "next";
import { LessonCard } from "../components";
import { course } from "../../lib/course";

export const metadata: Metadata = {
  title: "课程",
  description: "x86-64 操作系统实验课程索引。",
};

export default function LessonsPage() {
  return (
    <main className="page-shell shell">
      <header className="page-header">
        <p className="kicker">COURSE INDEX · 00—{course.lessons.at(-1)?.id}</p>
        <h1>沿着控制流，<br />逐层理解机器。</h1>
        <p>前六课已经完成；下一课将从单字符输出进入内存、指针与循环。</p>
      </header>

      <div className="lesson-grid lesson-grid--index">
        {course.lessons.map((lesson) => (
          <LessonCard key={lesson.slug} lesson={lesson} />
        ))}
      </div>
    </main>
  );
}
