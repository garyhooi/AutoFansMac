import { readFileSync } from "node:fs";
import { join } from "node:path";
import { ImageResponse } from "next/og";

export const runtime = "nodejs";

/**
 * The link card, written as a route handler at a path that ends in .png, so the static
 * export emits a real out/og.png. Next's opengraph-image convention would emit an
 * extensionless file, and a static host then has no extension to infer an image
 * content type from.
 *
 * A static export runs this once at build time, which is why it needs the explicit
 * static marking.
 */
export const dynamic = "force-static";

const size = { width: 1200, height: 630 };

/**
 * The card reads the brand mark from assets/, the same source the site's other images
 * are encoded from, so there is no second copy to keep in sync. If the icon cannot be
 * read the card still renders, just without it.
 */
function iconDataUrl(): string | null {
  try {
    const bytes = readFileSync(join(process.cwd(), "assets", "app-icon.png"));
    return `data:image/png;base64,${bytes.toString("base64")}`;
  } catch {
    return null;
  }
}

export function GET() {
  const icon = iconDataUrl();

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          background: "#08090a",
          padding: "72px 80px",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 22 }}>
          {icon ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={icon} alt="" width={76} height={76} style={{ borderRadius: 18 }} />
          ) : null}
          <div style={{ display: "flex", fontSize: 30, color: "#edeae6", letterSpacing: -0.5 }}>
            AutoFansMac
          </div>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 26 }}>
          <div
            style={{
              display: "flex",
              fontSize: 68,
              lineHeight: 1.05,
              letterSpacing: -2.6,
              color: "#edeae6",
              maxWidth: 900,
            }}
          >
            Take the fans back from macOS.
          </div>
          <div
            style={{
              display: "flex",
              height: 3,
              width: 132,
              background: "#8cf5fd",
              borderRadius: 999,
            }}
          />
          <div style={{ display: "flex", fontSize: 26, color: "#938f89", maxWidth: 880 }}>
            Free and open source. Native fan control and sensor monitoring, with one
            network request that can be switched off.
          </div>
        </div>

        <div style={{ display: "flex", fontSize: 21, color: "#74716c" }}>
          github.com/garyhooi/AutoFansMac
        </div>
      </div>
    ),
    size,
  );
}
