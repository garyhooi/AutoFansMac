import type { MetadataRoute } from "next";
import { SITE_URL, absolute } from "@/lib/seo";

/**
 * A static export turns this into a plain robots.txt file at build time, so it has to
 * be marked static explicitly.
 */
export const dynamic = "force-static";

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [{ userAgent: "*", allow: "/" }],
    sitemap: absolute("/sitemap.xml"),
    // The HOST directive is a bare hostname, never a URL. Yandex reads it; Google
    // ignores it, which is why the sitemap line carries the real signal.
    host: new URL(SITE_URL).host,
  };
}
