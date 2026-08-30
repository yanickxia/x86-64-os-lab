import { course } from "../content/course.generated";

export { course };

export type Lesson = (typeof course.lessons)[number];

export function getCourseSections() {
  return course.sections
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
