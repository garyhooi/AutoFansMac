import { CurveInstrument } from "@/components/CurveInstrument";
import { Reveal } from "@/components/motion/Reveal";
import { Icon } from "@/components/ui/Icon";
import { Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { curve } from "@/lib/site";

/**
 * The signature feature gets the widest section on the page, with the explanation
 * pinned beside it so the instrument stays in view while the notes are read.
 */
export function CurveSection() {
  return (
    <Section id="control">
      <div className="grid gap-12 lg:grid-cols-[minmax(0,0.44fr)_minmax(0,1fr)] lg:gap-16">
        <div className="lg:sticky lg:top-28 lg:self-start">
          <SectionHeading>{curve.headline}</SectionHeading>
          <Lede className="mt-5">{curve.body}</Lede>

          <ul className="mt-8 flex flex-col gap-4">
            {curve.notes.map((note) => (
              <li key={note} className="flex gap-2.5">
                <Icon name="CaretRight" size={12} className="mt-1.5 shrink-0 text-aqua-400" />
                <span className="measure text-[13.5px] leading-relaxed text-ash-400">{note}</span>
              </li>
            ))}
          </ul>

          <p className="mt-8 font-mono text-[12px] text-aqua-300/85">{curve.formula}</p>
        </div>

        <Reveal>
          <CurveInstrument />
        </Reveal>
      </div>
    </Section>
  );
}
