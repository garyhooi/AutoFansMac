"use client";

import { useRef, useState, type KeyboardEvent } from "react";
import { Check, Copy } from "@phosphor-icons/react/ssr";
import { MagnetCTA } from "@/components/motion/MagnetCTA";
import { DOWNLOAD_LABEL, RELEASES, install } from "@/lib/site";

/**
 * Three distribution routes as a tabbed panel.
 *
 * The copy button reports what actually happened: it says Copied only after the
 * clipboard promise resolves, and says so plainly when the browser refuses.
 */
export function InstallTabs() {
  const [active, setActive] = useState(0);
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  const tabRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const resetTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const tab = install.tabs[active];

  function select(index: number) {
    setActive(index);
    setState("idle");
  }

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const last = install.tabs.length - 1;
    let next = active;
    if (event.key === "ArrowRight") next = active === last ? 0 : active + 1;
    else if (event.key === "ArrowLeft") next = active === 0 ? last : active - 1;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = last;
    else return;
    event.preventDefault();
    select(next);
    tabRefs.current[next]?.focus();
  }

  async function copy() {
    if (resetTimer.current) clearTimeout(resetTimer.current);
    try {
      await navigator.clipboard.writeText(tab.lines.join("\n"));
      setState("copied");
    } catch {
      setState("failed");
    }
    resetTimer.current = setTimeout(() => setState("idle"), 2000);
  }

  return (
    <div className="flex flex-col gap-8">
      <div className="shell ambient">
        <div className="core p-4 sm:p-6">
          <div
            role="tablist"
            aria-label="Install routes"
            onKeyDown={onKeyDown}
            className="flex flex-wrap gap-1.5"
          >
            {install.tabs.map((entry, index) => (
              <button
                key={entry.id}
                ref={(node) => {
                  tabRefs.current[index] = node;
                }}
                role="tab"
                id={`tab-${entry.id}`}
                aria-selected={index === active}
                aria-controls={`panel-${entry.id}`}
                tabIndex={index === active ? 0 : -1}
                onClick={() => select(index)}
                className="rounded-full px-4 py-2 text-[13px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100 aria-selected:bg-white/[0.07] aria-selected:text-ash-100"
              >
                {entry.label}
              </button>
            ))}
          </div>

          <div
            role="tabpanel"
            id={`panel-${tab.id}`}
            aria-labelledby={`tab-${tab.id}`}
            className="mt-5"
          >
            <div className="rounded-[var(--radius-input)] border border-white/[0.07] bg-ink-1000">
              <div className="flex items-center justify-between gap-3 border-b border-white/[0.06] px-4 py-2.5">
                <span className="font-mono text-[11px] text-ash-500">Terminal</span>
                <button
                  type="button"
                  onClick={copy}
                  className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100"
                >
                  {state === "copied" ? (
                    <Check size={14} weight="bold" className="text-aqua-400" />
                  ) : (
                    <Copy size={14} />
                  )}
                  {state === "copied" ? "Copied" : state === "failed" ? "Copy failed" : "Copy"}
                </button>
              </div>
              <pre className="overflow-x-auto px-4 py-4 font-mono text-[12.5px] leading-relaxed text-ash-200">
                <code>
                  {tab.lines.map((line) => (
                    <span key={line} className="block">
                      <span aria-hidden="true" className="select-none text-aqua-500/70">
                         
                      </span>
                      {line}
                    </span>
                  ))}
                </code>
              </pre>
            </div>
            <p className="mt-3 text-[13.5px] leading-relaxed text-ash-400">{tab.note}</p>
          </div>
        </div>
      </div>

      <div className="flex flex-col gap-5 sm:flex-row sm:items-center sm:justify-between">
        <p className="measure text-[13.5px] leading-relaxed text-ash-400">{install.requirement}</p>
        <MagnetCTA href={RELEASES} label={DOWNLOAD_LABEL} className="shrink-0" />
      </div>
    </div>
  );
}
