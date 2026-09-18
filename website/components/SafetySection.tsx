import { SafetyRules } from "@/components/SafetyRules";
import { Reveal } from "@/components/motion/Reveal";
import { Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { safety } from "@/lib/site";

/** Four rules, then the actual constants the helper enforces them with. */
export function SafetySection() {
  return (
    <Section id="safety">
      <div className="max-w-[46rem]">
        <SectionHeading>{safety.headline}</SectionHeading>
        <Lede className="mt-5">{safety.body}</Lede>
      </div>

      <SafetyRules />

      <Reveal className="mt-14">
        <div className="core-flat px-6 py-7 sm:px-8">
          <dl className="grid grid-cols-1 gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
            {safety.bounds.map((bound) => (
              <div key={bound.label}>
                <dt className="text-[12.5px] text-ash-400">{bound.label}</dt>
                <dd className="mt-1.5 font-mono text-[13px] tracking-tight text-ash-100">
                  {bound.value}
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </Reveal>
    </Section>
  );
}
