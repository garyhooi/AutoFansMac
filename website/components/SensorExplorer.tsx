"use client";

import { useMemo, useState } from "react";
import { motion } from "motion/react";
import { MagnifyingGlass } from "@phosphor-icons/react/ssr";
import { CATALOG, CATALOG_TOTALS } from "@/lib/sensor-catalog";
import { revealItem } from "@/components/motion/Reveal";

const GROUPS = ["All", ...Object.keys(CATALOG_TOTALS.groups)];
const TYPES = ["All", ...Object.keys(CATALOG_TOTALS.types)];
const VISIBLE_LIMIT = 42;

/**
 * A browser over the keys the app ships names for. The list is generated from
 * Packages/SMCKit/Sources/SMCKit/SensorCatalogTable.swift, so it is the same table the
 * app reads rather than a hand-written sample.
 *
 * No data is fetched, so there is no loading state to show. The empty state is real:
 * it is what a visitor sees when they search for a key the catalog does not carry.
 */
export function SensorExplorer() {
  const [query, setQuery] = useState("");
  const [group, setGroup] = useState("All");
  const [type, setType] = useState("All");

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return CATALOG.filter((entry) => {
      if (group !== "All" && entry.group !== group) return false;
      if (type !== "All" && entry.type !== type) return false;
      if (!needle) return true;
      return (
        entry.key.toLowerCase().includes(needle) || entry.name.toLowerCase().includes(needle)
      );
    });
  }, [query, group, type]);

  const byGroup = useMemo(() => {
    const grouped = new Map<string, typeof filtered>();
    for (const entry of filtered.slice(0, VISIBLE_LIMIT)) {
      const list = grouped.get(entry.group) ?? [];
      list.push(entry);
      grouped.set(entry.group, list);
    }
    return [...grouped.entries()];
  }, [filtered]);

  const shown = Math.min(filtered.length, VISIBLE_LIMIT);

  return (
    <div className="flex flex-col gap-4">
      <div className="shell ambient">
        <div className="core p-4 sm:p-5">
          <div className="flex flex-col gap-2">
            <label
              htmlFor="sensor-search"
              className="font-mono text-[11px] text-ash-500"
            >
              Search keys and names
            </label>
            <div className="relative">
              <MagnifyingGlass
                size={16}
                aria-hidden="true"
                className="pointer-events-none absolute left-3.5 top-1/2 -translate-y-1/2 text-ash-500"
              />
              <input
                id="sensor-search"
                type="search"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                placeholder="TC0P, GPU diode, Memory"
                className="h-11 w-full rounded-[var(--radius-input)] border border-white/[0.1] bg-ink-900 pl-10 pr-3 text-[14px] text-ash-100 outline-none transition-colors duration-300 ease-swift placeholder:text-ash-400 hover:border-white/[0.16] focus-visible:border-aqua-500/70"
              />
            </div>
            <p className="text-[12px] text-ash-400">
              Unknown keys are not an error. The app lists them with their raw FourCC in an
              Unknown group.
            </p>
          </div>

          <div className="mt-5 flex flex-wrap items-center gap-x-2 gap-y-2">
            <span className="font-mono text-[11px] text-ash-500">Group</span>
            {GROUPS.map((entry) => (
              <button
                key={entry}
                type="button"
                onClick={() => setGroup(entry)}
                aria-pressed={group === entry}
                className="rounded-full border border-white/[0.09] px-3 py-1 text-[12px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100 aria-[pressed=true]:border-white/[0.18] aria-[pressed=true]:bg-white/[0.06] aria-[pressed=true]:text-ash-100"
              >
                {entry}
              </button>
            ))}
          </div>

          <div className="mt-2.5 flex flex-wrap items-center gap-x-2 gap-y-2">
            <span className="font-mono text-[11px] text-ash-500">Type</span>
            {TYPES.map((entry) => (
              <button
                key={entry}
                type="button"
                onClick={() => setType(entry)}
                aria-pressed={type === entry}
                className="rounded-full border border-white/[0.09] px-3 py-1 text-[12px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100 aria-[pressed=true]:border-white/[0.18] aria-[pressed=true]:bg-white/[0.06] aria-[pressed=true]:text-ash-100"
              >
                {entry}
              </button>
            ))}
          </div>

          <p aria-live="polite" className="mt-5 font-mono text-[11.5px] text-ash-500">
            {filtered.length === 0
              ? "No match"
              : `Showing ${shown} of ${filtered.length} matching keys, from ${CATALOG.length} literal keys in a ${CATALOG_TOTALS.entries}-entry catalog`}
          </p>
        </div>
      </div>

      {filtered.length === 0 ? (
        <div className="core-flat flex flex-col items-start gap-3 p-6">
          <p className="text-[15px] tracking-tight text-ash-100">
            Nothing in the catalog matches that.
          </p>
          <p className="measure text-[13.5px] leading-relaxed text-ash-400">
            The app still shows the key on your machine. It appears in the Unknown group with
            its raw FourCC, because a key the catalog does not carry is a gap in the catalog
            rather than a gap in the machine.
          </p>
          <button
            type="button"
            onClick={() => {
              setQuery("");
              setGroup("All");
              setType("All");
            }}
            className="rounded-full border border-white/[0.14] px-4 py-1.5 text-[13px] tracking-tight text-ash-100 transition-colors duration-300 ease-swift hover:bg-white/[0.05]"
          >
            Clear filters
          </button>
        </div>
      ) : (
        <motion.div
          className="core-flat p-3 sm:p-4"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true, amount: 0.1 }}
          variants={{ hidden: {}, visible: { transition: { staggerChildren: 0.02 } } }}
        >
          <div className="grid grid-cols-1 gap-x-6 md:grid-cols-2">
            {byGroup.map(([groupName, entries]) => (
              <div key={groupName} className="md:col-span-2 md:grid md:grid-cols-2 md:gap-x-6">
                <motion.p
                  variants={revealItem}
                  className="mt-3 border-b border-white/[0.07] pb-1.5 font-mono text-[11px] text-ash-500 md:col-span-2 md:mt-4"
                >
                  {groupName}
                </motion.p>
                {entries.map((entry) => (
                  <motion.div
                    key={`${entry.key}-${entry.name}`}
                    variants={revealItem}
                    className="flex items-baseline justify-between gap-3 rounded-lg px-3 py-2 transition-colors duration-200 hover:bg-white/[0.04]"
                  >
                    <span className="truncate text-[13.5px] tracking-tight text-ash-200">
                      {entry.name}
                    </span>
                    <span className="shrink-0 font-mono text-[11.5px] text-ash-500">
                      {entry.key}
                    </span>
                  </motion.div>
                ))}
              </div>
            ))}
          </div>
        </motion.div>
      )}
    </div>
  );
}
