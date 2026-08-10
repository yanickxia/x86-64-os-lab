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

export function MarkdownContent({ markdown }: { markdown: string }) {
  return (
    <div
      className="markdown-content"
      dangerouslySetInnerHTML={{ __html: renderMarkdown(markdown) }}
    />
  );
}
