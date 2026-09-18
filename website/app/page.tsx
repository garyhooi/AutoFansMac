import { ClaimsRail } from "@/components/ClaimsRail";
import { CompatibilitySection } from "@/components/CompatibilitySection";
import { CurveSection } from "@/components/CurveSection";
import { Hero } from "@/components/Hero";
import { InstallSection } from "@/components/InstallSection";
import { LimitsSection } from "@/components/LimitsSection";
import { SafetySection } from "@/components/SafetySection";
import { ScreensSection } from "@/components/ScreensSection";
import { SensorsSection } from "@/components/SensorsSection";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteNav } from "@/components/SiteNav";

export default function Page() {
  return (
    <>
      <SiteNav />
      <main>
        <Hero />
        <div className="mx-auto w-full max-w-[1400px] px-5 pb-20 sm:px-8 md:pb-28">
          <ClaimsRail />
        </div>
        <CurveSection />
        <SensorsSection />
        <ScreensSection />
        <SafetySection />
        <CompatibilitySection />
        <InstallSection />
        <LimitsSection />
      </main>
      <SiteFooter />
    </>
  );
}
