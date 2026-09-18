"use client";

import Image from "next/image";
import Link from "next/link";
import { AnimatePresence, motion } from "motion/react";
import { useEffect, useState } from "react";
import { MagnetCTA } from "@/components/motion/MagnetCTA";
import { DOWNLOAD_LABEL, RELEASES, navLinks } from "@/lib/site";
import { LAYER } from "@/lib/layers";

/**
 * A floating glass pill rather than an edge-to-edge bar. One line at every desktop
 * width, 56px tall, detached from the top of the viewport.
 *
 * There is no scroll listener: the bar does not change state on scroll, so it never
 * re-renders while the visitor is reading.
 */
export function SiteNav() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = previous;
      window.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <header className={`fixed inset-x-0 top-3 flex justify-center px-3 sm:top-4 sm:px-4 ${LAYER.nav}`}>
      <nav
        aria-label="Primary"
        className="flex w-full max-w-[1060px] items-center justify-between gap-2 rounded-full border border-white/[0.08] bg-ink-900/72 p-1.5 shadow-[0_20px_45px_-30px_rgba(0,0,0,0.95)] backdrop-blur-xl lg:w-max lg:justify-start"
      >
        <Link
          href="#top"
          className="flex items-center gap-2.5 rounded-full py-1.5 pl-2 pr-3 transition-colors duration-300 ease-swift hover:bg-white/[0.05]"
        >
          <Image
            src="/app-icon.webp"
            alt=""
            width={28}
            height={28}
            className="rounded-[8px]"
            priority
          />
          <span className="text-[13.5px] font-medium tracking-[-0.01em] text-ash-100">
            AutoFansMac
          </span>
        </Link>

        <span aria-hidden="true" className="hidden h-5 w-px bg-white/[0.09] lg:block" />

        <ul className="hidden items-center lg:flex">
          {navLinks.map((link) => (
            <li key={link.href}>
              <Link
                href={link.href}
                className="block rounded-full px-3 py-2 text-[13px] tracking-tight text-ash-400 transition-colors duration-300 ease-swift hover:bg-white/[0.05] hover:text-ash-100"
              >
                {link.label}
              </Link>
            </li>
          ))}
        </ul>

        <div className="flex items-center gap-1.5">
          <div className="hidden lg:block">
            <MagnetCTA href={RELEASES} label={DOWNLOAD_LABEL} compact />
          </div>

          <button
            type="button"
            onClick={() => setOpen((value) => !value)}
            aria-expanded={open}
            aria-controls="site-menu"
            className="flex h-11 w-11 items-center justify-center rounded-full border border-white/[0.1] text-ash-100 transition-colors duration-300 ease-swift hover:bg-white/[0.05] lg:hidden"
          >
            <span className="sr-only">{open ? "Close menu" : "Open menu"}</span>
            <span aria-hidden="true" className="relative block h-4 w-5">
              <span
                className={`absolute left-0 block h-px w-5 bg-current transition-all duration-500 ease-swift ${
                  open ? "top-[8px] rotate-45" : "top-[3px]"
                }`}
              />
              <span
                className={`absolute left-0 block h-px w-5 bg-current transition-all duration-500 ease-swift ${
                  open ? "top-[8px] -rotate-45" : "top-[13px]"
                }`}
              />
            </span>
          </button>
        </div>
      </nav>

      <AnimatePresence>
        {open ? (
          <motion.div
            id="site-menu"
            key="menu"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.35, ease: [0.32, 0.72, 0, 1] }}
            className={`fixed inset-0 ${LAYER.overlay} bg-ink-1000/94 backdrop-blur-2xl lg:hidden`}
          >
            <div className="flex h-full flex-col justify-between px-6 pb-10 pt-28">
              <ul className="flex flex-col gap-1">
                {navLinks.map((link, index) => (
                  <motion.li
                    key={link.href}
                    initial={{ y: 24 }}
                    animate={{ y: 0 }}
                    transition={{
                      duration: 0.55,
                      delay: 0.06 + index * 0.06,
                      ease: [0.16, 1, 0.3, 1],
                    }}
                  >
                    <Link
                      href={link.href}
                      onClick={() => setOpen(false)}
                      className="block py-3 text-3xl tracking-[-0.03em] text-ash-100"
                    >
                      {link.label}
                    </Link>
                  </motion.li>
                ))}
              </ul>
              <motion.div
                initial={{ y: 20 }}
                animate={{ y: 0 }}
                transition={{ duration: 0.5, delay: 0.34, ease: [0.16, 1, 0.3, 1] }}
              >
                <MagnetCTA href={RELEASES} label={DOWNLOAD_LABEL} />
              </motion.div>
            </div>
          </motion.div>
        ) : null}
      </AnimatePresence>
    </header>
  );
}
