"use client";

import { motion, useMotionValue, useReducedMotion, useSpring } from "motion/react";
import { ArrowUpRight } from "@phosphor-icons/react/ssr";
import { useRef, type PointerEvent } from "react";

const SPRING = { stiffness: 210, damping: 24, mass: 0.6 };

/**
 * The page's CTA. One component, so the single download intent has one label and one
 * look everywhere it appears (nav, hero, install, footer).
 *
 * The magnetic pull lives in motion values, never React state: pointer movement does
 * not re-render anything. Touch pointers and reduced motion skip it entirely.
 *
 * Contrast: ink on aqua is 15.9:1, aqua on ink is 15.8:1, ghost label on ink is 17:1.
 */
export function MagnetCTA({
  href,
  label,
  variant = "primary",
  compact = false,
  className = "",
}: {
  href: string;
  label: string;
  variant?: "primary" | "ghost";
  /** Smaller disc and padding, for the navigation pill. Same label either way. */
  compact?: boolean;
  className?: string;
}) {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLAnchorElement>(null);
  const rawX = useMotionValue(0);
  const rawY = useMotionValue(0);
  const x = useSpring(rawX, SPRING);
  const y = useSpring(rawY, SPRING);

  function handleMove(event: PointerEvent<HTMLAnchorElement>) {
    if (reduce || event.pointerType !== "mouse" || !ref.current) return;
    const rect = ref.current.getBoundingClientRect();
    const dx = event.clientX - (rect.left + rect.width / 2);
    const dy = event.clientY - (rect.top + rect.height / 2);
    rawX.set(Math.max(-14, Math.min(14, dx * 0.2)));
    rawY.set(Math.max(-9, Math.min(9, dy * 0.24)));
  }

  function handleLeave() {
    rawX.set(0);
    rawY.set(0);
  }

  const skin =
    variant === "primary"
      ? "bg-aqua-500 text-ink-1000 hover:bg-aqua-400"
      : "border border-white/[0.14] text-ash-100 hover:bg-white/[0.05]";

  const disc =
    variant === "primary" ? "bg-ink-1000/[0.14] text-ink-1000" : "bg-white/[0.07] text-ash-100";

  return (
    <motion.a
      ref={ref}
      href={href}
      target="_blank"
      rel="noreferrer"
      onPointerMove={handleMove}
      onPointerLeave={handleLeave}
      style={reduce ? undefined : { x, y }}
      className={`group inline-flex items-center whitespace-nowrap rounded-full font-medium tracking-tight transition-colors duration-500 ease-swift active:scale-[0.98] ${skin} ${
        compact ? "gap-2 py-1 pl-4 pr-1 text-[13px]" : "gap-3 py-1.5 pl-5 pr-1.5 text-[14.5px]"
      } ${className}`}
    >
      <span>{label}</span>
      <span
        className={`flex items-center justify-center rounded-full transition-transform duration-500 ease-swift group-hover:translate-x-0.5 group-hover:-translate-y-px group-hover:scale-105 ${
          compact ? "h-8 w-8" : "h-9 w-9"
        } ${disc}`}
      >
        <ArrowUpRight size={compact ? 15 : 17} weight="bold" />
      </span>
    </motion.a>
  );
}
