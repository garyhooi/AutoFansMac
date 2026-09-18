import Image from "next/image";
import { Reveal } from "@/components/motion/Reveal";
import { Caption, Lede, Section, SectionHeading, Shell } from "@/components/ui/Panel";
import { screens } from "@/lib/site";

/**
 * An asymmetric bento over the five surfaces. Every cell is real content: three shipped
 * window screenshots, one menu bar capture at its native size, and no filler.
 *
 * Captions sit below their frame rather than on top of the image, and nothing is
 * overlaid on a screenshot.
 */
export function ScreensSection() {
  const [profiles, sensorView, settingsView] = screens.tiles;

  return (
    <Section>
      <div className="max-w-[46rem]">
        <SectionHeading>{screens.headline}</SectionHeading>
        <Lede className="mt-5">{screens.body}</Lede>
      </div>

      <div className="mt-12 grid gap-5 lg:grid-cols-12">
        <Reveal className="lg:col-span-7">
          <Shot {...profiles} />
        </Reveal>

        <Reveal className="lg:col-span-5" delay={0.05}>
          <MenuBarTile />
        </Reveal>

        <Reveal className="lg:col-span-5">
          <Shot {...sensorView} />
        </Reveal>

        <Reveal className="lg:col-span-7" delay={0.05}>
          <Shot {...settingsView} />
        </Reveal>
      </div>
    </Section>
  );
}

/**
 * The 1x menu bar capture, framed by a bezel that hugs it instead of a column that
 * would stretch it. It is the smallest artifact on the page on purpose: the point of
 * the menu bar is that it is glanceable.
 */
function MenuBarTile() {
  const shot = screens.menuBar;

  return (
    <figure className="flex h-full flex-col">
      {/* w-fit so the bezel hugs a 1x asset instead of stretching it, clamped by
          max-w-full so it still fits a narrow column. */}
      <div className="shell ambient mx-auto w-fit max-w-full">
        <div className="core">
          <Image
            src={shot.src}
            alt={shot.alt}
            width={shot.width}
            height={shot.height}
            className="block h-auto w-[350px] max-w-full"
          />
        </div>
      </div>
      <figcaption className="mt-4 px-1">
        <span className="block text-[14px] tracking-tight text-ash-100">{shot.title}</span>
        <span className="measure mt-1 block text-[13px] leading-relaxed text-ash-400">
          {shot.body}
        </span>
      </figcaption>
    </figure>
  );
}

function Shot({
  src,
  alt,
  title,
  body,
}: {
  src: string;
  alt: string;
  title: string;
  body: string;
}) {
  return (
    <figure className="flex h-full flex-col">
      <Shell tight className="ambient">
        <div className="core">
          <Image
            src={src}
            alt={alt}
            width={1012}
            height={684}
            className="h-auto w-full"
          />
        </div>
      </Shell>
      <figcaption className="mt-4 px-1">
        <span className="block text-[14px] tracking-tight text-ash-100">{title}</span>
        <span className="measure mt-1 block text-[13px] leading-relaxed text-ash-400">
          {body}
        </span>
      </figcaption>
    </figure>
  );
}
