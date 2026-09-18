import { LICENSE, REPO, RELEASES, limits } from "@/lib/site";

/**
 * Search and social metadata in one place, so the title, the description, the canonical
 * URL and the structured data cannot disagree with each other.
 *
 * Nothing here is guesswork:
 *   version    MARKETING_VERSION in AutoFansMac.xcodeproj/project.pbxproj
 *   author     the repository's commit author and the MIT copyright line
 *   price      the app is free and MIT licensed, so the offer is 0 USD
 *   FAQ        the same array the Limits section renders, so the markup cannot drift
 *              from the visible content
 */

export const SITE_NAME = "AutoFansMac";

/**
 * The canonical origin, resolved at build time because a static export bakes it into
 * canonical, Open Graph, sitemap.xml, robots.txt and the JSON-LD:
 *
 *   1. NEXT_PUBLIC_SITE_URL   set this on the Production environment
 *   2. CF_PAGES_URL           Cloudflare's own URL for this deployment
 *   3. localhost              a local build
 *
 * Step 2 is what keeps a first deploy honest: without it an unconfigured Cloudflare
 * build would publish "localhost:3210" as its canonical URL.
 */
const RAW_SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL ?? process.env.CF_PAGES_URL ?? "http://localhost:3210";

export const SITE_URL = RAW_SITE_URL.replace(/\/+$/, "");

/**
 * A Pages preview deployment is reachable at its own *.pages.dev URL. Left indexable it
 * competes with production for the same content, so a preview is marked noindex.
 *
 * Production is identified the same way the URL is: an explicit NEXT_PUBLIC_SITE_URL, or
 * the production branch. Set NEXT_PUBLIC_SITE_URL on the Production environment only.
 * A local build has no CF_PAGES_BRANCH and is therefore never a preview.
 */
const PRODUCTION_BRANCH = process.env.NEXT_PUBLIC_PRODUCTION_BRANCH ?? "main";

export const IS_PREVIEW =
  !process.env.NEXT_PUBLIC_SITE_URL &&
  Boolean(process.env.CF_PAGES_BRANCH) &&
  process.env.CF_PAGES_BRANCH !== PRODUCTION_BRANCH;

export const absolute = (path: string) =>
  `${SITE_URL}${path.startsWith("/") ? path : `/${path}`}`;

export const SOFTWARE_VERSION = "1.0.0";

export const AUTHOR = {
  name: "Gary Hooi",
  url: "https://github.com/garyhooi",
} as const;

export const TITLE = "AutoFansMac: free, open source macOS fan control";

export const DESCRIPTION =
  "Free and open source Mac fan control. Read every SMC sensor, ramp fans on a curve you draw, and keep every write inside the range the firmware reports.";

export const KEYWORDS = [
  "mac fan control",
  "free fan control mac",
  "open source fan control",
  "SMC fan control",
  "macOS fan speed",
  "Apple Silicon fan control",
  "mac temperature sensors",
  "menu bar fan control",
  "thermal monitoring Mac",
];

/** The five shipped screenshots, as absolute URLs for the app entity. */
const SHOTS = [
  "/shots/fans.webp",
  "/shots/sensors.webp",
  "/shots/profiles.webp",
  "/shots/settings.webp",
  "/shots/menu-bar.webp",
].map(absolute);

/**
 * The link card is a real file at a real path with an extension, generated at build
 * time by app/og.png/route.tsx. Next's opengraph-image convention would emit an
 * extensionless file, which a static host then serves without an image content type.
 */
export const OG_IMAGE = {
  url: "/og.png",
  width: 1200,
  height: 630,
  type: "image/png",
} as const;

export const OG_ALT =
  "AutoFansMac, free and open source fan control and sensor monitoring for macOS";

export const structuredData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": `${SITE_URL}/#website`,
      url: `${SITE_URL}/`,
      name: SITE_NAME,
      description: DESCRIPTION,
      inLanguage: "en",
      publisher: { "@id": `${SITE_URL}/#author` },
    },
    {
      "@type": "WebPage",
      "@id": `${SITE_URL}/#webpage`,
      url: `${SITE_URL}/`,
      name: TITLE,
      description: DESCRIPTION,
      isPartOf: { "@id": `${SITE_URL}/#website` },
      about: { "@id": `${SITE_URL}/#app` },
      primaryImageOfPage: absolute(OG_IMAGE.url),
      inLanguage: "en",
    },
    {
      "@type": "Person",
      "@id": `${SITE_URL}/#author`,
      name: AUTHOR.name,
      url: AUTHOR.url,
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE_URL}/#app`,
      name: SITE_NAME,
      applicationCategory: "UtilitiesApplication",
      applicationSubCategory: "Fan control and hardware monitoring",
      operatingSystem: "macOS 13 Ventura or later",
      processorRequirements: "Apple Silicon or Intel",
      softwareVersion: SOFTWARE_VERSION,
      softwareRequirements: "Xcode 15 or later to build from source",
      downloadUrl: RELEASES,
      installUrl: RELEASES,
      codeRepository: REPO,
      softwareHelp: `${REPO}/blob/main/Docs/README-DEV.md`,
      license: "https://opensource.org/license/mit",
      isAccessibleForFree: true,
      inLanguage: "en",
      screenshot: SHOTS,
      featureList: [
        "Reads every SMC temperature, voltage, power, current and fan sensor",
        "Constant RPM and sensor-based curve modes",
        "Unlimited profiles plus the built-in Automatic and Full Blast",
        "Thermal floor override, per-write clamping and a 60 second dead-man switch",
      ],
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
        availability: "https://schema.org/InStock",
        url: RELEASES,
      },
      author: { "@id": `${SITE_URL}/#author` },
      publisher: { "@id": `${SITE_URL}/#author` },
      sameAs: [REPO],
    },
    {
      "@type": "FAQPage",
      "@id": `${SITE_URL}/#faq`,
      mainEntity: limits.items.map((item) => ({
        "@type": "Question",
        name: item.q,
        acceptedAnswer: { "@type": "Answer", text: item.a },
      })),
    },
  ],
} satisfies Record<string, unknown>;

export const LICENSE_URL = LICENSE;