/**
 * Serves the exported site from out/ the way a static host does.
 *
 * next start cannot serve a static export, so this is how the real artifact gets
 * checked locally: clean URLs, correct content types straight off the file extension,
 * and 404.html for anything missing.
 *
 *   bun run preview
 */
import { existsSync } from "node:fs";
import { dirname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "out");
const port = Number(process.env.PORT ?? 3210);

if (!existsSync(join(root, "index.html"))) {
  console.error("out/ is empty. Run: bun run build");
  process.exit(1);
}

function resolveFile(pathname) {
  // normalize() collapses any ../ before it can escape the export directory.
  const relative = normalize(decodeURIComponent(pathname)).replace(/^(\.\.[/\\])+/, "");
  const candidates = [relative, relative.replace(/\/$/, "") + "/index.html", relative + ".html"];
  for (const candidate of candidates) {
    const full = join(root, candidate);
    if (existsSync(full) && !full.endsWith("/")) return full;
  }
  return null;
}

Bun.serve({
  port,
  fetch(request) {
    const { pathname } = new URL(request.url);
    const file = resolveFile(pathname || "/");
    if (file) return new Response(Bun.file(file));
    return new Response(Bun.file(join(root, "404.html")), {
      status: 404,
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
});

console.log(`serving out/ on http://localhost:${port}`);
