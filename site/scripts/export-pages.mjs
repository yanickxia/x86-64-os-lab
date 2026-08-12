import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const courseRoot = path.resolve(siteRoot, "..");
const distRoot = path.join(siteRoot, "dist");
const outputRoot = path.join(siteRoot, "out");

function normaliseBasePath(value) {
  const withLeadingSlash = value.startsWith("/") ? value : `/${value}`;
  const withoutTrailingSlash = withLeadingSlash.replace(/\/+$/, "");
  return withoutTrailingSlash === "/" ? "" : withoutTrailingSlash;
}

const basePath = normaliseBasePath(process.env.PAGES_BASE_PATH ?? "/x86-64-os-lab");

async function getWorker() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("pages-export", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker;
}

function makeStatic(html) {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<link\b[^>]*\brel=["']modulepreload["'][^>]*>/gi, "")
    .replace(/((?:href|src|data-rsc-css-href)=["'])\/(?!\/)/g, `$1${basePath}/`);
}

function outputFileForRoute(route) {
  return route === "/"
    ? path.join(outputRoot, "index.html")
    : path.join(outputRoot, route.slice(1), "index.html");
}

async function renderRoute(worker, route) {
  const response = await worker.fetch(
    new Request(`http://localhost${route}`, { headers: { accept: "text/html" } }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );

  if (response.status !== 200) {
    throw new Error(`Cannot export ${route}: HTTP ${response.status}`);
  }

  const outputFile = outputFileForRoute(route);
  await mkdir(path.dirname(outputFile), { recursive: true });
  await writeFile(outputFile, makeStatic(await response.text()), "utf8");
}

async function exists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function validatePage(route) {
  const outputFile = outputFileForRoute(route);
  const html = await readFile(outputFile, "utf8");

  if (/<script\b/i.test(html)) {
    throw new Error(`${route} still contains runtime scripts`);
  }

  const absolutePaths = [...html.matchAll(/(?:href|src)=["'](\/[^"']*)["']/g)].map((match) => match[1]);

  for (const absolutePath of absolutePaths) {
    if (basePath && absolutePath !== basePath && !absolutePath.startsWith(`${basePath}/`)) {
      throw new Error(`${route} contains a path outside the Pages base: ${absolutePath}`);
    }

    const relativeUrl = (basePath ? absolutePath.slice(basePath.length) : absolutePath).split(/[?#]/, 1)[0] || "/";
    const target = relativeUrl === "/"
      ? path.join(outputRoot, "index.html")
      : path.extname(relativeUrl)
        ? path.join(outputRoot, relativeUrl.slice(1))
        : path.join(outputRoot, relativeUrl.slice(1), "index.html");

    if (!(await exists(target))) {
      throw new Error(`${route} links to a missing export target: ${absolutePath}`);
    }
  }
}

const lessonRoutes = (await readdir(path.join(courseRoot, "docs")))
  .filter((name) => /^lesson-\d{2}\.md$/.test(name))
  .sort()
  .map((name) => `/lessons/${name.slice(0, -3)}`);
const routes = ["/", "/lessons", ...lessonRoutes, "/roadmap", "/reference"];

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });
await cp(path.join(distRoot, "client"), outputRoot, { recursive: true });

const worker = await getWorker();
for (const route of routes) {
  await renderRoute(worker, route);
}

await cp(path.join(outputRoot, "index.html"), path.join(outputRoot, "404.html"));
await writeFile(path.join(outputRoot, ".nojekyll"), "", "utf8");

for (const route of routes) {
  await validatePage(route);
}

console.log(`Exported ${routes.length} static routes to ${outputRoot} with base path '${basePath || "/"}'`);
