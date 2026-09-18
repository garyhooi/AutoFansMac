import Image from "next/image";
import Link from "next/link";
import { MagnetCTA } from "@/components/motion/MagnetCTA";
import { DOWNLOAD_LABEL, RELEASES, footer } from "@/lib/site";

/**
 * Closing conversion point. No version string, no build stamp, no locale strip: the
 * licence, the attribution and one download.
 */
export function SiteFooter() {
  return (
    <footer className="relative border-t border-white/[0.07] pb-10 pt-16">
      <div className="mx-auto w-full max-w-[1400px] px-5 sm:px-8">
        <div className="grid gap-12 lg:grid-cols-[minmax(0,1.5fr)_repeat(3,minmax(0,1fr))]">
          <div>
            <div className="flex items-center gap-3">
              <Image
                src="/app-icon.webp"
                alt=""
                width={36}
                height={36}
                className="rounded-[10px]"
              />
              <span className="text-[15px] font-medium tracking-tight text-ash-100">
                AutoFansMac
              </span>
            </div>
            <p className="measure mt-5 text-[13.5px] leading-relaxed text-ash-400">
              {footer.tagline}
            </p>
            <div className="mt-7">
              <MagnetCTA href={RELEASES} label={DOWNLOAD_LABEL} />
            </div>
          </div>

          {footer.columns.map((column) => (
            <nav key={column.title} aria-label={column.title}>
              <h2 className="text-[13px] tracking-tight text-ash-200">{column.title}</h2>
              <ul className="mt-4 flex flex-col gap-2.5">
                {column.links.map((link) => (
                  <li key={link.label}>
                    <Link
                      href={link.href}
                      target="_blank"
                      rel="noreferrer"
                      className="inline-block py-1 text-[13.5px] text-ash-400 transition-colors duration-300 ease-swift hover:text-ash-100"
                    >
                      {link.label}
                    </Link>
                  </li>
                ))}
              </ul>
            </nav>
          ))}
        </div>

        <div className="mt-14 flex flex-col gap-2 border-t border-white/[0.07] pt-6 sm:flex-row sm:items-center sm:justify-between">
          <p className="text-[12.5px] text-ash-400">
            Free and open source under the MIT licence. Sensor naming data derived from
            Stats, also MIT.
          </p>
          <p className="font-mono text-[12px] text-ash-500">
            macOS 13 Ventura or later, Apple Silicon and Intel
          </p>
        </div>
      </div>
    </footer>
  );
}
