import { RevealCell, RevealGrid } from "@/components/motion/Reveal";
import { Badge, Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { compatibility } from "@/lib/site";

type Status = keyof typeof compatibility.legend;

/** Eight machines, one card each, with the status the project can actually defend. */
export function CompatibilitySection() {
  return (
    <Section id="compatibility">
      <div className="max-w-[46rem]">
        <SectionHeading>{compatibility.headline}</SectionHeading>
        <Lede className="mt-5">{compatibility.body}</Lede>
      </div>

      <RevealGrid className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {compatibility.machines.map((machine) => {
          const status = machine.status as Status;
          const tone = status === "verified" || status === "simulated" ? "accent" : "neutral";
          return (
            <RevealCell key={machine.generation}>
              <article className="core-flat flex h-full flex-col gap-4 p-5">
                <header className="flex items-start justify-between gap-3">
                  <h3 className="text-[16px] tracking-tight text-ash-100">{machine.generation}</h3>
                  <Badge tone={tone}>{compatibility.legend[status]}</Badge>
                </header>

                <p className="font-mono text-[11.5px] leading-relaxed text-ash-500">
                  {machine.example}
                </p>

                <dl className="flex flex-col gap-2.5">
                  <div className="flex items-baseline justify-between gap-3">
                    <dt className="text-[12px] text-ash-400">Mode key</dt>
                    <dd className="font-mono text-[12px] text-ash-200">{machine.modeKey}</dd>
                  </div>
                  <div className="flex items-baseline justify-between gap-3">
                    <dt className="text-[12px] text-ash-400">Unlock</dt>
                    <dd className="text-right font-mono text-[12px] text-ash-200">
                      {machine.unlock}
                    </dd>
                  </div>
                </dl>

                <p className="mt-auto text-[12.5px] leading-relaxed text-ash-400">
                  {machine.note}
                </p>
              </article>
            </RevealCell>
          );
        })}
      </RevealGrid>
    </Section>
  );
}
