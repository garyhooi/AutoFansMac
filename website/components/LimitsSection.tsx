import { Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { limits } from "@/lib/site";

/**
 * The disclosures, as native details elements. No JavaScript, keyboard accessible for
 * free, and open by default nowhere so the section stays scannable.
 */
export function LimitsSection() {
  return (
    <Section>
      <div className="max-w-[46rem]">
        <SectionHeading>{limits.headline}</SectionHeading>
        <Lede className="mt-5">{limits.body}</Lede>
      </div>

      <div className="mt-12 grid gap-x-12 md:grid-cols-2">
        {limits.items.map((item) => (
          <details key={item.q} className="group border-t border-white/[0.07] py-3.5">
            <summary className="flex cursor-pointer list-none items-start justify-between gap-4 py-1.5 text-[15px] tracking-tight text-ash-100 [&::-webkit-details-marker]:hidden">
              {item.q}
              <span
                aria-hidden="true"
                className="relative mt-1.5 block h-3 w-3 shrink-0 text-ash-400 transition-transform duration-500 ease-swift group-open:rotate-45"
              >
                <span className="absolute left-0 top-1/2 h-px w-3 -translate-y-1/2 bg-current" />
                <span className="absolute left-1/2 top-0 h-3 w-px -translate-x-1/2 bg-current" />
              </span>
            </summary>
            <p className="measure mt-3 animate-rise text-[13.5px] leading-relaxed text-ash-400">
              {item.a}
            </p>
          </details>
        ))}
      </div>
    </Section>
  );
}
