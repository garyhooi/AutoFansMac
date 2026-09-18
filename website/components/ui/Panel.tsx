import type { ReactNode } from "react";

/**
 * The page's structural primitives.
 *
 * Shape lock, applied everywhere and nowhere else:
 *   shells .shell          28px, a tray
 *   cores  .core / .core-flat  20px, the plate inside the tray
 *   controls                 full pill
 *   inputs                  12px
 */

export function Section({
  id,
  children,
  className = "",
}: {
  id?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section id={id} className={`relative py-24 md:py-32 ${className}`}>
      <div className="mx-auto w-full max-w-[1400px] px-5 sm:px-8">{children}</div>
    </section>
  );
}

export function Shell({
  children,
  className = "",
  tight = false,
}: {
  children: ReactNode;
  className?: string;
  tight?: boolean;
}) {
  return (
    <div className={`shell ${tight ? "shell-tight" : ""} ${className}`}>{children}</div>
  );
}


/** A small mono label. Used as a caption, never stacked above a section headline. */
export function Caption({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <p className={`font-mono text-[11.5px] text-ash-400 ${className}`}>{children}</p>
  );
}

export function SectionHeading({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <h2
      className={`text-[1.75rem] leading-[1.08] tracking-[-0.035em] text-ash-100 sm:text-4xl lg:text-[2.6rem] ${className}`}
    >
      {children}
    </h2>
  );
}

export function Lede({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <p
      className={`measure text-[0.95rem] leading-relaxed text-ash-400 sm:text-base ${className}`}
    >
      {children}
    </p>
  );
}

export function Badge({
  children,
  tone = "neutral",
  className = "",
}: {
  children: ReactNode;
  tone?: "neutral" | "accent";
  className?: string;
}) {
  const tones = {
    neutral: "border-white/10 bg-white/[0.03] text-ash-300",
    accent: "border-aqua-700/45 bg-aqua-950/35 text-aqua-200",
  } as const;
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2.5 py-0.5 font-mono text-[11px] tracking-tight ${tones[tone]} ${className}`}
    >
      {children}
    </span>
  );
}
