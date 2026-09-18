/**
 * Pre-encodes the site's images to WebP.
 *
 * The build is a static export, so Next's Image Optimization API is gone and every
 * image ships exactly as written. That makes this script the only thing standing
 * between a 292 KB app icon and a 28 px slot on the page.
 *
 * The outputs are committed, so this only has to run when an asset changes. It is
 * deliberately NOT part of the build command: Cloudflare's build image would then need
 * cwebp, and a deploy should not depend on a local encoder.
 *
 *   bun run images
 *
 * Requires cwebp (brew install webp).
 *
 * Encoding rules, and why:
 *   large window shots   lossy q88. They are displayed downscaled (1012 px source into a
 *                        531 to 771 px slot), which hides compression artifacts.
 *   menu bar shot        lossless. It is displayed at 1:1, so it is the one image where
 *                        ringing around text would actually be visible.
 *   app icon             96 px, lossy q88. Displayed at 28 and 36 px, so 96 covers 2x.
 */
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, "..");
const assets = join(site, "assets");
const out = join(site, "public");

const jobs = [
  ...["fans", "sensors", "profiles", "settings"].map((name) => ({
    from: join(assets, "shots", `${name}.png`),
    to: join(out, "shots", `${name}.webp`),
    args: ["-q", "88", "-m", "6", "-sharp_yuv"],
  })),
  {
    from: join(assets, "shots", "menu-bar.png"),
    to: join(out, "shots", "menu-bar.webp"),
    args: ["-z", "9"],
  },
  {
    from: join(assets, "app-icon.png"),
    to: join(out, "app-icon.webp"),
    args: ["-q", "88", "-m", "6", "-resize", "96", "96"],
  },
];

function hasCwebp() {
  try {
    execFileSync("cwebp", ["-version"], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

if (!hasCwebp()) {
  console.error("cwebp not found. Install it with: brew install webp");
  process.exit(1);
}

let before = 0;
let after = 0;

for (const job of jobs) {
  if (!existsSync(job.from)) {
    console.error(`missing source: ${job.from}`);
    process.exit(1);
  }
  mkdirSync(dirname(job.to), { recursive: true });
  execFileSync("cwebp", ["-quiet", ...job.args, job.from, "-o", job.to]);
  const a = statSync(job.from).size;
  const b = statSync(job.to).size;
  before += a;
  after += b;
  const label = job.to.slice(site.length + 1);
  console.log(
    `${label.padEnd(28)} ${String(Math.round(a / 1024)).padStart(5)} KB -> ${String(Math.round(b / 1024)).padStart(4)} KB`,
  );
}

console.log(
  `
${jobs.length} images: ${Math.round(before / 1024)} KB -> ${Math.round(after / 1024)} KB (${(before / after).toFixed(1)}x smaller)`,
);
