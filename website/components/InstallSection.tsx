import { InstallTabs } from "@/components/InstallTabs";
import { Reveal } from "@/components/motion/Reveal";
import { Lede, Section, SectionHeading } from "@/components/ui/Panel";
import { install } from "@/lib/site";

export function InstallSection() {
  return (
    <Section id="install">
      <div className="max-w-[46rem]">
        <SectionHeading>{install.headline}</SectionHeading>
        <Lede className="mt-5">{install.body}</Lede>
      </div>
      <Reveal className="mt-10">
        <InstallTabs />
      </Reveal>
    </Section>
  );
}
