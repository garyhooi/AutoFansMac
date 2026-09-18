import type { MetadataRoute } from "next";
import { absolute } from "@/lib/seo";

/**
 * One page, so the sitemap is one entry. lastModified is the build time: the page is
 * statically generated, so that is the last moment its content certainly changed.
 *
 * A static export writes this to sitemap.xml at build time, which requires the explicit
 * static marking.
 */
export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: absolute("/"),
      lastModified: new Date(),
      changeFrequency: "monthly",
      priority: 1,
    },
  ];
}
