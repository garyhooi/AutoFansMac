"use client";

import { motion, useReducedMotion } from "motion/react";
import type { ReactNode } from "react";

/**
 * Scroll entry.
 *
 * One rule here is deliberate: entrance motion never animates opacity on text. A
 * fade-in is measurably low contrast while it runs, and an accessibility audit that
 * scrolls the page samples exactly that moment. Moving the element and easing its blur
 * keeps the page visibly alive without a frame of unreadable copy, and it removes a
 * flaky failure that says nothing about the settled page.
 *
 * Only transform and filter are animated. Reduced motion collapses to a plain element.
 * IntersectionObserver does the triggering; there is no scroll listener on this page.
 */
export function Reveal({
  children,
  className,
  delay = 0,
  y = 16,
  blur = false,
}: {
  children: ReactNode;
  className?: string;
  delay?: number;
  y?: number;
  blur?: boolean;
}) {
  const reduce = useReducedMotion();

  if (reduce) {
    return <div className={className}>{children}</div>;
  }

  return (
    <motion.div
      className={className}
      initial={blur ? { y, filter: "blur(8px)" } : { y }}
      whileInView={blur ? { y: 0, filter: "blur(0px)" } : { y: 0 }}
      viewport={{ once: true, amount: 0.2 }}
      transition={{ duration: 0.7, delay, ease: [0.16, 1, 0.3, 1] }}
    >
      {children}
    </motion.div>
  );
}

/**
 * Grid stagger. Parent and cells share this one Client Component module, so variants
 * propagate through the motion context; cell contents still render on the server and
 * arrive as children.
 */
export function RevealGrid({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  const reduce = useReducedMotion();
  if (reduce) return <div className={className}>{children}</div>;
  return (
    <motion.div
      className={className}
      initial="hidden"
      whileInView="visible"
      viewport={{ once: true, amount: 0.1 }}
      variants={{ hidden: {}, visible: { transition: { staggerChildren: 0.05 } } }}
    >
      {children}
    </motion.div>
  );
}

export function RevealCell({ children }: { children: ReactNode }) {
  return (
    <motion.div variants={revealItem} className="h-full">
      {children}
    </motion.div>
  );
}

export const revealItem = {
  hidden: { y: 16 },
  visible: {
    y: 0,
    transition: { duration: 0.6, ease: [0.16, 1, 0.3, 1] as const },
  },
};
