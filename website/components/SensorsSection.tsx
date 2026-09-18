import { SensorExplorer } from "@/components/SensorExplorer";
import { Reveal } from "@/components/motion/Reveal";
import { Caption, Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { sensorsSection } from "@/lib/site";

/**
 * Full-width family: the header stacks, the measured numbers run as one band, and the
 * browser takes the whole measure below it.
 */
export function SensorsSection() {
  return (
    <Section id="sensors">
      <div className="max-w-[46rem]">
        <SectionHeading>{sensorsSection.headline}</SectionHeading>
        <Lede className="mt-5">{sensorsSection.body}</Lede>
      </div>

      <div className="mt-10 border-y border-white/[0.07] py-7">
        <dl className="grid grid-cols-2 gap-x-8 gap-y-6 sm:grid-cols-4">
          {sensorsSection.stats.map((stat) => (
            <div key={stat.label}>
              <dt className="text-[12.5px] text-ash-400">{stat.label}</dt>
              <dd className="mt-1.5 font-mono text-2xl tracking-tight text-ash-100">
                {stat.value}
              </dd>
            </div>
          ))}
        </dl>
        <Caption className="mt-6">
          Measured on a MacBook Pro Mac17,9 with an M5 Pro, running macOS 27.0.
        </Caption>
      </div>

      <Reveal className="mt-10">
        <SensorExplorer />
      </Reveal>
    </Section>
  );
}
