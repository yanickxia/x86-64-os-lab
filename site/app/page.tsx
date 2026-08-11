import type { Metadata } from "next";
import Link from "next/link";
import { LessonSectionList, StatusBadge } from "./components";
import { course, getCourseSections } from "../lib/course";

export const metadata: Metadata = {
  title: "从 CPU 复位到自己的内核",
  description: "一套用 QEMU、GDB 与反汇编逐步验证的 x86-64 操作系统学习笔记。",
};

export default function Home() {
  const nextLesson = course.lessons.find((lesson) => lesson.status === "next");
  const sections = getCourseSections();
  const progress = Math.round((course.completedCount / course.lessons.length) * 100);

  return (
    <main>
      <section className="hero shell">
        <div className="hero__copy">
          <p className="kicker">PERSONAL OPERATING SYSTEM LAB · X86-64</p>
          <h1>从复位向量，<br />走到自己的内核。</h1>
          <p className="hero__lede">
            不是把代码拼到能跑，而是沿着机器真实执行的路径，逐条建立可解释、可调试、可复现的证据。
          </p>
          <div className="hero__actions">
            <Link className="button button--primary" href="/lessons">查看全部课程</Link>
            {nextLesson && (
              <Link className="button button--ghost" href={`/lessons/${nextLesson.slug}`}>
                继续第 {Number(nextLesson.id)} 课
              </Link>
            )}
          </div>
        </div>

        <aside className="boot-trace" aria-label="当前学习进度">
          <div className="boot-trace__head">
            <span>BOOT TRACE</span>
            <span>{progress}%</span>
          </div>
          <div className="progress-track"><span style={{ width: `${progress}%` }} /></div>
          <ol>
            <li><span>0xfffffff0</span><strong>RESET VECTOR</strong></li>
            <li><span>0x00007c00</span><strong>BOOT SECTOR</strong></li>
            <li><span>0x00007bfe</span><strong>REAL STACK</strong></li>
            <li><span>port 0x00e9</span><strong>FIRST OUTPUT</strong></li>
            <li><span>0x00001000</span><strong>PML4 ROOT</strong></li>
            <li><span>0x00007d30</span><strong>CS64 ENTRY</strong></li>
          </ol>
          <div className="boot-trace__summary">
            <strong>{course.completedCount}</strong>
            <span>节已完成 / 共 {course.lessons.length} 节</span>
          </div>
        </aside>
      </section>

      {nextLesson ? (
        <section className="next-up shell">
          <div>
            <p className="eyebrow">NEXT CHECKPOINT</p>
            <h2>下一步：{nextLesson.phase}</h2>
            <p>{nextLesson.summary}</p>
          </div>
          <div className="next-up__meta">
            <StatusBadge status={nextLesson.status} />
            <code>{nextLesson.takeaway}</code>
            <Link href={`/lessons/${nextLesson.slug}`}>打开课程 →</Link>
          </div>
        </section>
      ) : (
        <section className="next-up shell">
          <div>
            <p className="eyebrow">MILESTONE REACHED</p>
            <h2>可执行的 Stage 2 边界已建立</h2>
            <p>stage 1 已能完整加载并调用独立 stage 2；加载起点、镜像尾部、执行握手和返回旧路径都有彼此独立的机器证据。</p>
          </div>
          <div className="next-up__meta">
            <StatusBadge status="completed" />
            <code>STAGE 1 → STAGE 2 → RETURN</code>
            <Link href="/roadmap">查看后续路线 →</Link>
          </div>
        </section>
      )}

      <section className="section shell">
        <div className="section-heading">
          <div>
            <p className="eyebrow">LEARNING TRACE</p>
            <h2>每一步都有机器证据</h2>
          </div>
          <Link href="/lessons">课程总览 →</Link>
        </div>
        <LessonSectionList sections={sections} />
      </section>

      <section className="method-section shell">
        <div className="method-section__intro">
          <p className="eyebrow">METHOD</p>
          <h2>预测、运行、取证、复盘。</h2>
          <p>同一套方法会贯穿启动、内存、异常、用户态、调度与文件系统。</p>
        </div>
        <div className="method-list">
          <article><span>01</span><h3>先写预测</h3><p>把直觉暴露出来，错误才有学习价值。</p></article>
          <article><span>02</span><h3>最小改动</h3><p>一次只引入一个机制，控制变量。</p></article>
          <article><span>03</span><h3>机器取证</h3><p>用 GDB、原始字节和测试验证，而非只看表象。</p></article>
          <article><span>04</span><h3>留下解释</h3><p>记录控制流、不变量和失败原因。</p></article>
        </div>
      </section>
    </main>
  );
}
