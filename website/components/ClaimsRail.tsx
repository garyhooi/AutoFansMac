"use client";

import { motion } from "motion/react";
import { Icon, type IconName } from "@/components/ui/Icon";
import { claims } from "@/lib/site";
import { revealItem } from "@/components/motion/Reveal";

/**
 * Five claims that are checkable in the repository, not adjectives. Drawn as a single
 * hairline rail rather than a row of cards.
 */
export function ClaimsRail() {
  return (
    <motion.ul
      className="grid grid-cols-1 gap-px overflow-hidden rounded-[var(--radius-core)] border border-white/[0.07] bg-white/[0.055] sm:grid-cols-2 lg:grid-cols-5"
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, amount: 0.2 }}
      variants={{ hidden: {}, visible: { transition: { staggerChildren: 0.05 } } }}
    >
      {claims.map((claim, index) => (
        <motion.li
          key={claim.label}
          variants={revealItem}
          className={`flex items-center gap-3 bg-ink-950 px-5 py-6 ${
            index === claims.length - 1 ? "sm:col-span-2 lg:col-span-1" : ""
          }`}
        >
          <Icon name={claim.icon as IconName} size={18} className="shrink-0 text-aqua-400" />
          <span className="text-[13.5px] tracking-tight text-ash-200">{claim.label}</span>
        </motion.li>
      ))}
    </motion.ul>
  );
}
