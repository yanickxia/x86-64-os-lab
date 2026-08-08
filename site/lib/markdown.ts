import { marked } from "marked";

marked.setOptions({
  gfm: true,
  breaks: false,
});

function normalizeInternalLinks(markdown: string) {
  return markdown
    .replace(/\]\(reference\/assembly-basics\.md\)/g, "](/reference)")
    .replace(/\]\(roadmap\.md\)/g, "](/roadmap)");
}
function stripFirstHeading(markdown: string) {
  return markdown.replace(/^#\s+.+\n+/, "");
}

function plainHeading(markdown: string) {
  return markdown
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[*_~]/g, "")
    .trim();
}

export function getTableOfContents(markdown: string) {
  return [...markdown.matchAll(/^##\s+(.+)$/gm)].map((match, index) => ({
    id: `section-${index + 1}`,
    label: plainHeading(match[1]),
  }));
}

export function renderMarkdown(markdown: string) {
  const source = normalizeInternalLinks(stripFirstHeading(markdown));
  let section = 0;
  const html = marked.parse(source, { async: false }) as string;

  return html.replace(/<h2>(.*?)<\/h2>/g, (_match, contents) => {
    section += 1;
    return `<h2 id="section-${section}">${contents}</h2>`;
  });
}
