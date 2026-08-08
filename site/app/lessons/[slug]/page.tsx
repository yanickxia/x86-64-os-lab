import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { MarkdownContent, StatusBadge } from "../../components";
import { course, getLesson, getLessonNeighbors } from "../../../lib/course";
import { getTableOfContents } from "../../../lib/markdown";

type LessonPageProps = {
  params: Promise<{ slug: string }>;
};

export function generateStaticParams() {
  return course.lessons.map((lesson) => ({ slug: lesson.slug }));
}
export async function generateMetadata({ params }: LessonPageProps): Promise<Metadata> {
  const { slug } = await params;
  const lesson = getLesson(slug);
  return lesson
    ? { title: lesson.title, description: lesson.summary }
    : { title: "课程未找到" };
}

export default async function LessonPage({ params }: LessonPageProps) {
  const { slug } = await params;
  const lesson = getLesson(slug);
  if (!lesson) notFound();

  const toc = getTableOfContents(lesson.markdown);
  const neighbors = getLessonNeighbors(slug);

  return (
    <main className="lesson-page shell">
      <header className="lesson-hero">
        <div className="lesson-hero__number">{lesson.id}</div>
        <div>
          <div className="lesson-hero__meta">
            <span>{lesson.phase}</span>
            <StatusBadge status={lesson.status} />
          </div>
          <h1>{lesson.title}</h1>
          <p>{lesson.summary}</p>
          <code>{lesson.takeaway}</code>
        </div>
      </header>

      <div className="lesson-layout">
        <article className="lesson-article">
          <MarkdownContent markdown={lesson.markdown} />

          {lesson.status === "completed" && (
            <details className="learning-log">
              <summary>
                <span>我的学习记录</span>
                <small>展开实验预测、观察与复盘</small>
              </summary>
              <MarkdownContent markdown={lesson.notes} />
            </details>
          )}

          <nav className="lesson-pagination" aria-label="课程翻页">
            {neighbors.previous ? (
              <Link href={`/lessons/${neighbors.previous.slug}`}>
                <small>上一课</small>
                <span>← {neighbors.previous.title}</span>
              </Link>
            ) : <span />}
            {neighbors.next && (
              <Link className="is-next" href={`/lessons/${neighbors.next.slug}`}>
                <small>下一课</small>
                <span>{neighbors.next.title} →</span>
              </Link>
            )}
          </nav>
        </article>

        <aside className="lesson-rail">
          <div className="rail-card">
            <p className="eyebrow">IN THIS LESSON</p>
            <ol>
              {toc.map((item) => (
                <li key={item.id}><a href={`#${item.id}`}>{item.label}</a></li>
              ))}
            </ol>
          </div>
          <div className="rail-card rail-card--progress">
            <span>{course.completedCount}/{course.lessons.length}</span>
            <p>当前课程进度</p>
            <Link href="/roadmap">查看完整路线图 →</Link>
          </div>
        </aside>
      </div>
    </main>
  );
}
