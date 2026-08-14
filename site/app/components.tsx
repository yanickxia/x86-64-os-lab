import Link from "next/link";
import type { Lesson } from "../lib/course";
import { renderMarkdown } from "../lib/markdown";

export function SiteHeader() {
  return (
    <header className="site-header">
      <div className="site-header__inner">
        <Link className="wordmark" href="/" aria-label="x86-64 OS Field Notes 首页">
          <span className="wordmark__mark">x64</span>
          <span className="wordmark__text">
            <strong>OS Field Notes</strong>
            <small>from reset to kernel</small>
          </span>
        </Link>
        <nav className="main-nav" aria-label="主导航">
          <Link href="/lessons">课程</Link>
          <Link href="/roadmap">路线图</Link>
          <Link href="/reference">汇编参考</Link>
          <Link href="/reference/c">C 参考</Link>
        </nav>
      </div>
    </header>
  );
}

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <p>x86-64 OS Field Notes</p>
      <p>每个结论，都留下一条可重复的证据链。</p>
    </footer>
  );
}

export function StatusBadge({ status }: { status: Lesson["status"] }) {
  const display = status === "completed"
    ? { className: "is-complete", icon: "✓", label: "已完成" }
    : status === "next"
      ? { className: "is-next", icon: "→", label: "下一课" }
      : { className: "is-upcoming", icon: "·", label: "随后" };

  return (
    <span className={`status-badge ${display.className}`}>
      <span aria-hidden="true">{display.icon}</span>
      {display.label}
    </span>
  );
}

export function LessonCard({ lesson }: { lesson: Lesson }) {
  return (
    <Link className="lesson-card" href={`/lessons/${lesson.slug}`}>
      <div className="lesson-card__topline">
        <span className="lesson-number">{lesson.id}</span>
        <StatusBadge status={lesson.status} />
      </div>
      <p className="eyebrow">{lesson.phase}</p>
      <h3>{lesson.title.replace(/^第\s*\d+\s*课[：:]\s*/, "")}</h3>
      <p>{lesson.summary}</p>
      <code>{lesson.takeaway}</code>
    </Link>
  );
}

type LessonSection = {
  id: string;
  title: string;
  description: string;
  lessons: readonly Lesson[];
};

export function LessonSectionList({ sections, index = false }: {
  sections: readonly LessonSection[];
  index?: boolean;
}) {
  const hasNextLesson = sections.some((section) =>
    section.lessons.some((lesson) => lesson.status === "next")
  );
  const latestLesson = sections.at(-1)?.lessons.at(-1);

  return (
    <div className="lesson-sections">
      {sections.map((section) => {
        const completedCount = section.lessons.filter(
          (lesson) => lesson.status === "completed",
        ).length;
        const isCurrent = section.lessons.some((lesson) => lesson.status === "next") ||
          (!hasNextLesson && section.lessons.some((lesson) => lesson.slug === latestLesson?.slug));
        const firstLesson = section.lessons[0];
        const lastLesson = section.lessons.at(-1);

        return (
          <details
            className={`lesson-section${isCurrent ? " is-current" : ""}`}
            id={`section-${section.id}`}
            key={section.id}
            open={isCurrent}
          >
            <summary>
              <span className="lesson-section__index">SECTION {section.id}</span>
              <span className="lesson-section__copy">
                <strong>{section.title}</strong>
                <small>{section.description}</small>
              </span>
              <span className="lesson-section__meta">
                <code>{firstLesson.id}—{lastLesson?.id}</code>
                <small>{completedCount}/{section.lessons.length} 已完成</small>
                <span className="lesson-section__chevron" aria-hidden="true">⌄</span>
              </span>
            </summary>
            <div className={`lesson-grid${index ? " lesson-grid--index" : ""}`}>
              {section.lessons.map((lesson) => (
                <LessonCard key={lesson.slug} lesson={lesson} />
              ))}
            </div>
          </details>
        );
      })}
    </div>
  );
}

export function MarkdownContent({ markdown }: { markdown: string }) {
  return (
    <div
      className="markdown-content"
      dangerouslySetInnerHTML={{ __html: renderMarkdown(markdown) }}
    />
  );
}
