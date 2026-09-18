import Image from "next/image";
import { MagnetCTA } from "@/components/motion/MagnetCTA";
import { Caption, Shell } from "@/components/ui/Panel";
import { Reveal } from "@/components/motion/Reveal";
import { DOWNLOAD_LABEL, RELEASES, REPO, SOURCE_LABEL, hero } from "@/lib/site";

/**
 * Asymmetric split hero: the claim on the left, the actual window on the right.
 *
 * Four text elements, no more: two platform chips, the headline, one sentence, two
 * CTAs. Everything else the visitor might want to know lives in the sections below.
 */
export function Hero() {
  return (
    <section id="top" className="relative overflow-hidden pb-16 pt-24 md:pb-24">
      {/* Ambient warmth behind the product shot. Atmosphere, not a glow on a control. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute -top-32 right-[-12%] h-[620px] w-[620px] rounded-full bg-[radial-gradient(circle,rgba(140,245,253,0.12),rgba(140,245,253,0)_62%)]"
      />

      <div className="relative mx-auto w-full max-w-[1400px] px-5 sm:px-8">
        <div className="grid grid-cols-1 items-center gap-12 lg:grid-cols-[minmax(0,1.02fr)_minmax(0,1fr)] lg:gap-16">
          <div>
            <div className="flex flex-wrap gap-2">
              {hero.chips.map((chip) => (
                <span
                  key={chip}
                  className="rounded-full border border-white/[0.09] bg-white/[0.03] px-3 py-1 font-mono text-[11.5px] tracking-tight text-ash-400"
                >
                  {chip}
                </span>
              ))}
            </div>

            <h1 className="mt-6 text-[2.25rem] leading-[0.98] tracking-[-0.045em] text-ash-100 md:text-5xl xl:text-6xl">
              {hero.headline}
            </h1>

            <p className="measure mt-6 text-[1.0625rem] leading-relaxed text-ash-300 md:text-lg">
              {hero.subtext}
            </p>

            <div className="mt-9 flex flex-wrap items-center gap-3">
              <MagnetCTA href={RELEASES} label={DOWNLOAD_LABEL} />
              <MagnetCTA href={REPO} label={SOURCE_LABEL} variant="ghost" />
            </div>
          </div>

          <Reveal blur delay={0.05}>
            <Shell className="ambient">
              <div className="core">
                <Image
                  src="/shots/fans.webp"
                  alt="The AutoFansMac Fans view: two fans with their mode, an editable sensor curve with Tmin and Tmax, and a live preview of the ramp."
                  width={1012}
                  height={684}
                  priority
                  className="h-auto w-full"
                />
              </div>
            </Shell>
            <Caption className="mt-3 px-1">{hero.caption}</Caption>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
