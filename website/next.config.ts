import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /**
   * Cloudflare Pages serves static files, so this is a static export: out/ rather than
   * .next/, and no Node runtime at the edge.
   *
   * images.unoptimized is required by output: "export", because the Image Optimization
   * API is a server feature. With the optimizer out of the picture every image is
   * pre-encoded to WebP by the images script; see README, Assets.
   */
  output: "export",
  images: { unoptimized: true },
  reactStrictMode: true,
  poweredByHeader: false,
  turbopack: {
    // The site is a subdirectory of the app repository, and Turbopack workspace-root
    // inference walks up past it to an unrelated lockfile in the home directory.
    // Pinning the root here keeps the build quiet and file tracing scoped to the site.
    root: __dirname,
  },
};

export default nextConfig;
