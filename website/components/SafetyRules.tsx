"use client";

import { motion } from "motion/react";
import { Icon, type IconName } from "@/components/ui/Icon";
import { revealItem } from "@/components/motion/Reveal";
import { safety } from "@/lib/site";

/**
 * The four rules, staggered on entry. Parent and children share one Client Component
 * tree so the variants actually propagate.
 */
export function SafetyRules() {
  return (
    <motion.div
      className="mt-12 grid gap-x-10 gap-y-9 md:grid-cols-2"
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, amount: 0.15 }}
      variants={{ hidden: {}, visible: { transition: { staggerChildren: 0.07 } } }}
    >
      {safety.rules.map((rule) => (
        <motion.div key={rule.title} variants={revealItem} className="flex gap-4">
          <Icon
            name={rule.icon as IconName}
            size={22}
            className="mt-0.5 shrink-0 text-aqua-400"
          />
          <div>
            <h3 className="text-[15.5px] tracking-tight text-ash-100">{rule.title}</h3>
            <p className="measure mt-2 text-[13.5px] leading-relaxed text-ash-400">{rule.body}</p>
          </div>
        </motion.div>
      ))}
    </motion.div>
  );
}
