import { course } from "../content/course.generated";

export { course };

export type Lesson = (typeof course.lessons)[number];

const courseSectionMeta = [
  {
    id: "01",
    from: 0,
    to: 6,
    title: "从复位到程序控制流",
    description: "建立实验环境，跟随 BIOS 启动，并在实模式中掌握端口、栈、调用与内存遍历。",
  },
  {
    id: "02",
    from: 7,
    to: 11,
    title: "进入 x86-64 Long Mode",
    description: "跨过 A20、GDT、保护模式和分页，把 CPU 带到可执行 64 位代码的环境。",
  },
  {
    id: "03",
    from: 12,
    to: 14,
    title: "加载、交接与 ELF",
    description: "把独立载荷读入内存、移交执行权，并让链接地址与真实运行地址一致。",
  },
  {
    id: "04",
    from: 15,
    to: 17,
    title: "启动复盘与理解检验",
    description: "串起完整启动路径，对照不同 CPU 架构，并用阶段考试检查因果链是否稳固。",
  },
  {
    id: "05",
    from: 18,
    to: Number.POSITIVE_INFINITY,
    title: "C 内核与 Bootloader 毕业",
    description: "建立 C 与异常入口后，补齐多扇区、boot info、ELF 与运行环境合同，再进入 OS 主线。",
  },
] as const;

export function getCourseSections() {
  return courseSectionMeta
    .map((section) => ({
      ...section,
      lessons: course.lessons.filter((lesson) => {
        const lessonNumber = Number(lesson.id);
        return lessonNumber >= section.from && lessonNumber <= section.to;
      }),
    }))
    .filter((section) => section.lessons.length > 0);
}

export function getLesson(slug: string) {
  return course.lessons.find((lesson) => lesson.slug === slug);
}
export function getLessonNeighbors(slug: string) {
  const index = course.lessons.findIndex((lesson) => lesson.slug === slug);
  return {
    previous: index > 0 ? course.lessons[index - 1] : undefined,
    next: index >= 0 && index < course.lessons.length - 1
      ? course.lessons[index + 1]
      : undefined,
  };
}
