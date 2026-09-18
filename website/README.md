# AutoFansMac website

The marketing site for [AutoFansMac](..), built with Next.js (App Router), TypeScript,
Tailwind v4 and Motion. It is a separate app inside the repository: the Xcode project
does not reference it, and nothing here is part of the shipped binary.

## Run it

```sh
cd website
bun install
bun run dev        # http://localhost:3210
bun run build      # static export into out/
bun run preview    # serve out/ the way a static host does, on :3210
bun run typecheck  # tsc --noEmit
bun run catalog    # regenerate lib/sensor-catalog.ts from the app's table
bun run images     # re-encode the shots to WebP (needs cwebp)
```

The build is a static export, so `next start` does not apply: `bun run preview` serves
`out/` with content types taken from the file extension and `404.html` for anything
missing.

`NEXT_PUBLIC_SITE_URL` sets the canonical origin that ends up in `canonical`, Open Graph,
`sitemap.xml`, `robots.txt` and the JSON-LD. Unset, the build falls back to Cloudflare's
`CF_PAGES_URL`, and then to `http://localhost:3210`. It is read at build time, so
changing it needs a rebuild rather than a redeploy.

Bun is the package manager and `bun.lock` is committed. Bun keeps its install cache
outside the repository, so the only thing the install adds to the tree is the lockfile.
`bun run dev` starts Next the ordinary way; `bun --bun run dev` puts Next itself on the
Bun runtime, which is optional and not needed for this site.

## Design read

> A product landing page for macOS power users and developers, with a precise
> machined-instrument language, leaning toward Next.js App Router, Tailwind v4,
> Geist and Geist Mono, and Motion.

Dials, set from that read:

| Dial | Value | Why |
|---|---|---|
| `DESIGN_VARIANCE` | 8 | Asymmetric split hero, fractional grids, offset bento. The audience is technical and reads structure. |
| `MOTION_INTENSITY` | 6 | Scroll reveals plus one genuinely interactive instrument. No scroll hijacking, no cinematic set pieces. |
| `VISUAL_DENSITY` | 5 | Slightly above airy, because this audience wants the measured numbers, and slightly below a table, because it is still a landing page. |

## The locks

These are held for the whole page. Changing one means auditing every section.

**Theme.** Dark only. The app's own UI is dark, so a light page would put four dark
rectangles on a white background. `color-scheme: dark` and a fixed `themeColor` are set
from `app/layout.tsx`.

**Accent.** Exactly one: `--color-aqua-500` `#8CF5FD`, taken from the app icon. It is
used for live data (the ramp, the marker, the temperature) and for the single CTA intent,
and nowhere else. It clears 15.9:1 against the page in both directions, so it works as a
fill and as text.

**Neutrals.** One warm grey ramp (`ash-100` to `ash-600`), never mixed with cool greys.
The warm ramp against a cool accent is deliberate. `ash-500` is the micro-label colour
and is pinned at 5:1, because it carries 10 to 12px text. `ash-600` is non-text only.

**Shape.** Shells 28px, cores 20px, controls full pill, inputs and code blocks 12px.
Shells and cores are concentric: 28 minus two 4px paddings is 20.

**Type.** Geist for interface and headings, Geist Mono for every number and every key.
No serif anywhere. Headline tracking is negative (`-0.045em` at hero scale).

**Motion.** Every transition is a spring or one of two cubic-bezier curves
(`--ease-swift`, `--ease-out-expo`). No `linear`, no default `ease-in-out`.

**Entrance motion never animates opacity on text.** Scroll reveals move the element and
ease its blur; they do not fade it. A fade-in is measurably low contrast while it runs,
which is exactly the moment an accessibility audit samples when it scrolls the page. With
transform-only entry the settled page and the entering page both pass, so the result is
deterministic instead of timing-dependent. The one remaining opacity animation is the
full-screen mobile menu scrim, which carries no text of its own.

**Layers.** Three z-indexes exist, in `lib/layers.ts`: 40 for the navigation, 50 for the
mobile menu, 60 for the grain overlay declared in `globals.css`.

## Structure

```
app/
  layout.tsx             fonts, metadata, viewport, grain, skip link
  page.tsx               section order
  opengraph-image.tsx    the link card, generated from the icon
  globals.css            tokens, base layer, shell/core, slider, grain
components/
  SiteNav.tsx            floating glass pill plus the full-screen mobile menu
  Hero.tsx               asymmetric split, real screenshot, one caption
  ClaimsRail.tsx         five checkable claims on a hairline rail
  CurveSection.tsx       the ramp explanation
  CurveInstrument.tsx    the interactive model of the shipped ramp maths
  SensorsSection.tsx     measurements band plus the catalog browser
  SensorExplorer.tsx     search and filter over the generated catalog
  ScreensSection.tsx     asymmetric bento over the five surfaces
  SafetySection.tsx      the four rules
  SafetyRules.tsx        staggered grid of those rules
  CompatibilitySection.tsx  eight machines with defensible status labels
  InstallSection.tsx     three distribution routes
  InstallTabs.tsx        tablist, code blocks, copy feedback
  LimitsSection.tsx      native details disclosures
  SiteFooter.tsx         attribution, licence, one download
  ui/Icon.tsx            the Phosphor registry, imported from the SSR entry
  ui/Panel.tsx           Section, Shell, Caption, SectionHeading, Lede, Badge
  motion/Reveal.tsx      scroll entry, grid stagger, reduced-motion collapse
  motion/MagnetCTA.tsx   the one CTA, magnetic on fine pointers
lib/
  site.ts                every visible string and outbound link
  sensor-catalog.ts      GENERATED from the app's sensor table
  layers.ts              the z-index scale
scripts/
  generate-sensor-catalog.mjs
```

## The one generated file

`lib/sensor-catalog.ts` is generated from
`Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift` so the site cannot drift from
the names the app actually ships:

```sh
bun run catalog          # or: bun website/scripts/generate-sensor-catalog.mjs
```

It keeps the 171 entries whose keys are literal FourCCs. Wildcard families such as
`TC%c` need a runtime index, so they are described rather than faked into concrete keys.

## Deploying to Cloudflare

The build is a static export, so a deploy is a file upload with no runtime.

Cloudflare Pages, importing this repository:

| Setting | Value |
|---|---|
| Root directory | `website` |
| Framework preset | Next.js (Static HTML Export) |
| Build command | `bun install --frozen-lockfile && bun run build` |
| Build output directory | `out` |
| Environment variable | `NEXT_PUBLIC_SITE_URL`, Production only |

**Root directory is the setting that is easy to miss.** The site lives in `website/` and
there is no `package.json` at the repository root, so without it `bun install` runs against
the Swift project and fails. The output directory is relative to the root directory; if you
leave the root directory blank instead, the command has to become
`cd website && bun install --frozen-lockfile && bun run build` and the output directory
`website/out`.

`--frozen-lockfile` makes the deploy use the committed `bun.lock` rather than quietly
resolving something else. Cloudflare's build image ships Bun, so `BUN_VERSION` only matters
if you want a specific one: `packageManager: bun@1.3.14` in `package.json` does not block a
different Bun.

### A deployment is pinned to its commit

Cloudflare binds a deployment to the commit that triggered it. If a build fails with
`Cannot find cwd: .../website`, it is building a commit from before the site existed and
the root directory has nothing to resolve against. Re-running that same deployment retries
the same commit; trigger a new one instead (push to the production branch).

The build command runs *inside* the root directory, so it must not `cd website` itself,
and the build output directory is relative to the root directory: `out`.

### The environment variable is not optional

`NEXT_PUBLIC_SITE_URL` is read at build time and baked into the canonical link,
`og:image`, `sitemap.xml`, `robots.txt` and the JSON-LD. Set it on Production only:

- with it, canonical is your domain and the site is indexable;
- without it, a production build falls back to `CF_PAGES_URL`, so a first deploy is honest
  rather than pointing at localhost;
- any other branch is marked `noindex` automatically, so preview URLs never compete with
  production for the same content. See `IS_PREVIEW` in `lib/seo.ts`.

### Workers with static assets

`wrangler.jsonc` carries `pages_build_output_dir`, which is what `wrangler pages deploy`
and the Pages dashboard read. To ship as a Worker with static assets instead, swap that
property for the `assets` block in the file's own comment. The artifact is the same
directory either way, and `out/404.html` is what `not_found_handling: "404-page"` serves.

Without a Git integration, `bun run build && bunx wrangler pages deploy out --project-name autofansmac-site` ships the same artifact from a terminal.

### There is no image resizing at the edge

`output: "export"` requires `images.unoptimized`, so nothing resizes an image on the way
out. Every image is pre-encoded by `bun run images` (see Assets) and the results are
committed. That script is deliberately kept out of the build command so a deploy never
depends on a local encoder.

### Response headers

`public/_headers` becomes `out/_headers`, and Pages and Workers static assets apply it
with no configuration. It carries six rules: four security headers (`nosniff`,
`strict-origin-when-cross-origin`, `X-Frame-Options: DENY`, and a `Permissions-Policy`
that denies everything the site never asks for) on every response including the 404, a
year of `immutable` caching on the content-hashed `/_next/static/*`, and a week with a
revalidation window on `/shots/*` and the two icon files.

Two things are deliberately absent. HSTS belongs at the zone level, where it covers every
host on the domain and is awkward to walk back. A Content-Security-Policy is worth having
once it can be tested against a live deploy: Next inlines its own bootstrap script, so a
policy that is wrong fails closed and takes the whole page with it.

### Checking the export locally

```sh
bun run build && bun run preview   # serves out/ the way a static host does
```

`next start` cannot serve a static export, which is why the preview script exists.

## Assets

Screenshots live in `public/shots/` and the app icon in `public/app-icon.png`. The four
window captures are 1012 by 684 and are displayed at up to 771 CSS px, so they are
downscaled and stay sharp at any density.

| File | Size | Displayed at | Notes |
|---|---|---|---|
| `fans.png` | 1012x684 | 612 px | hero |
| `profiles.png` | 1012x684 | 757 px | bento |
| `sensors.png` | 1012x684 | 531 px | bento |
| `settings.png` | 1012x684 | 757 px | bento |
| `menu-bar.png` | 350x295 | 350 px | 1x capture, see below |

`menu-bar.png` is a **1x** capture: the menu items measure about 13 px tall, which is
13 pt at 1x. It is therefore shown at its native 350 px inside a bezel that hugs it,
never stretched to fill a column. At that size it is crisp on a standard display and
soft on a Retina display, where each source pixel covers four device pixels.

Two things would sharpen it, and both are drop-in changes:

- a 2x export at 700x590, which only needs `width` and `height` updated in
  `screens.menuBar` in `lib/site.ts`;
- a capture whose surround is transparent, so the bezel frames the popover instead of
  the wallpaper behind it. The current capture is fully opaque and its background is
  wallpaper-tinted (roughly `rgb(8,19,40)` against the page's `rgb(8,9,10)`), which is
  why it sits inside a bezel rather than directly on the page.

## Search, social and structured data

`lib/seo.ts` owns every value that leaves the page for a crawler: the canonical URL, the
title, the description, the Open Graph and Twitter cards, and one `@graph` of JSON-LD.
Change the copy in one place and the markup follows.

The graph declares five entities: `WebSite`, `WebPage`, `Person` (the author),
`SoftwareApplication` and `FAQPage`.

"Free and open source" is encoded for machines rather than only written for people:

| Field | Value |
|---|---|
| `isAccessibleForFree` | `true` |
| `offers.price` | `0` `USD`, availability `InStock` |
| `license` | `https://opensource.org/license/mit` |
| `codeRepository` | the GitHub repository |
| `softwareVersion` | `1.0.0`, matching `MARKETING_VERSION` in the Xcode project |
| `operatingSystem` / `processorRequirements` | macOS 13 Ventura or later, Apple Silicon or Intel |
| `screenshot` | the five shipped screenshots, as absolute URLs |

The `FAQPage` is generated from `limits.items` in `lib/site.ts`, which is the same array
the Limits section renders. That is deliberate: FAQ markup that describes content a
visitor cannot see is against Google's structured data policy, and sharing the array
makes drift impossible. Google now reserves FAQ rich results for a small set of
authoritative sites, so treat this entry as entity and topic signal rather than as a
guaranteed rich snippet.

`app/robots.ts` and `app/sitemap.ts` are generated routes. The sitemap carries one URL
with the build time as `lastModified`.

### What this setup deliberately does not do

- No keyword stuffing in the H1. The headline stays "Take the fans back from macOS." and
  the search terms live in the title, the description, the first paragraph and the body
  copy, where a reader also benefits from them.
- No invented domain. `NEXT_PUBLIC_SITE_URL` is required for correct canonical, Open
  Graph, sitemap and robots output; without it everything points at localhost.
- No `manifest.webmanifest`. This is a landing page for a native app, not a web app, and
  an installable-manifest signal would be misleading.

## Verified

Run against the static export (`bun run build`, then `bun run preview`):

| Check | Result |
|---|---|
| `next build` | clean, static, no warnings |
| Lighthouse | Accessibility 100, Best Practices 100, SEO 100, 61 audits passed, 0 failed, stable across three consecutive runs |
| Contrast | 0 violations, computed per text node against its real composited background, and no ancestor of any text node drops below opacity 1 while entering |
| Structured data | one `@graph` of 5 entities parses; all 6 FAQ questions and their answers are present in the visible HTML |
| Crawl files | `/robots.txt` and `/sitemap.xml` generated and valid |
| Cloudflare headers | `wrangler pages dev` parsed 6 rules and applied them: security headers on every response including the 404, `immutable` on `/_next/static/*`, a week on `/shots/*` |
| Cloudflare URLs | with only `CF_PAGES_URL` set, canonical, Open Graph, the sitemap and the JSON-LD all resolve to that origin; a non-`main` branch publishes `noindex, follow` |
| Deploy shape | `out/` is 1.9 MB, 772 KB of it outside `_next`; `og.png`, `robots.txt`, `sitemap.xml` and `404.html` are all present |
| Core Web Vitals | LCP 826 ms, INP 22 ms, CLS 0.00 |
| Layout | 0 horizontal overflow at 390, 768, 1024, 1280 and 1512 px |
| Copy | 0 em-dashes and 0 en-dashes in source, DOM and rendered HTML |
| Animation | 6 distinct temperatures and a growing trail over 2 s; paused when the chart leaves the viewport |

## Content rules

Every number on the page is traceable to the repository, and each one names its source:

| Claim | Source |
|---|---|
| 200-entry catalog, group and type counts | `SensorCatalogTable.swift` |
| 3611 keys, 413 decoded values, 0.34 ms per key | `Docs/COMPATIBILITY.md`, Mac17,9 observation |
| `F0Mn` 2317, `F0Mx` 7826 | same observation, used as the demo fan's range |
| Ramp maths, EMA alpha 0.3, 50 RPM write threshold, 10 s sensor loss | `AutoFansMac/Services/CurveEngine.swift` |
| 95 C floor, 10 C hysteresis, 60 s heartbeat, 5 s re-assert | `Shared/HelperProtocol.swift` |
| `F0md` lowercase and no `Ftst` on M5 | `Docs/COMPATIBILITY.md` |

House rule for `lib/site.ts`: no em-dashes and no en-dashes. The page has zero of both,
in copy and in markup.