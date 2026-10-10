"use client";

import { useEffect, useState } from "react";
import { AnimatePresence, motion, useMotionValue, useSpring } from "motion/react";
import { TONES, type Tone } from "@/lib/site";
import { Triangle } from "./triangle";

/**
 * A little ClickBait that follows the visitor's own cursor around the page, taking the
 * colour of the section in view, and saying something about a few things it passes over
 * (`data-quip`). Only with a mouse or trackpad, and never with reduced motion.
 */
export function CursorBuddy() {
  const [enabled, setEnabled] = useState(false);
  const [visible, setVisible] = useState(false);
  const [tone, setTone] = useState<Tone>("azure");
  const [quip, setQuip] = useState<string | null>(null);
  const x = useMotionValue(-100);
  const y = useMotionValue(-100);
  const springX = useSpring(x, { stiffness: 500, damping: 40, mass: 0.6 });
  const springY = useSpring(y, { stiffness: 500, damping: 40, mass: 0.6 });

  useEffect(() => {
    const fine = window.matchMedia("(pointer: fine)");
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
    const update = () => setEnabled(fine.matches && !reduce.matches);
    update();
    fine.addEventListener("change", update);
    reduce.addEventListener("change", update);
    return () => {
      fine.removeEventListener("change", update);
      reduce.removeEventListener("change", update);
    };
  }, []);

  useEffect(() => {
    if (!enabled) return;
    const move = (event: PointerEvent) => {
      // Down and right of the pointer's tip, like the app.
      x.set(event.clientX + 14);
      y.set(event.clientY + 18);
      setVisible(true);
      const target = (event.target as Element | null)?.closest<HTMLElement>("[data-quip]");
      setQuip(target?.dataset.quip ?? null);
    };
    const leave = () => setVisible(false);
    window.addEventListener("pointermove", move, { passive: true });
    document.documentElement.addEventListener("pointerleave", leave);

    // The section most in view sets the colour.
    const sections = Array.from(document.querySelectorAll<HTMLElement>("[data-tone]"));
    const observer = new IntersectionObserver(
      (entries) => {
        const best = entries.filter((e) => e.isIntersecting).sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
        if (best) setTone(best.target.getAttribute("data-tone") as Tone);
      },
      { threshold: [0.25, 0.5, 0.75], rootMargin: "-30% 0px -30% 0px" },
    );
    sections.forEach((s) => observer.observe(s));
    return () => {
      window.removeEventListener("pointermove", move);
      document.documentElement.removeEventListener("pointerleave", leave);
      observer.disconnect();
    };
  }, [enabled, x, y]);

  if (!enabled) return null;
  return (
    <motion.div
      aria-hidden="true"
      className="pointer-events-none fixed left-0 top-0 z-[70]"
      style={{ x: springX, y: springY }}
      animate={{ opacity: visible ? 1 : 0 }}
      transition={{ duration: 0.2 }}
    >
      <Triangle tone={tone} size={18} />
      <AnimatePresence>
        {quip && (
          <motion.span
            key={quip}
            initial={{ opacity: 0, scale: 0.9, x: -4 }}
            animate={{ opacity: 1, scale: 1, x: 0 }}
            exit={{ opacity: 0, scale: 0.9 }}
            transition={{ duration: 0.18 }}
            className="absolute left-5 top-4 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-semibold text-white"
            style={{ background: TONES[tone].hex, boxShadow: `0 0 16px ${TONES[tone].hex}66` }}
          >
            {quip}
          </motion.span>
        )}
      </AnimatePresence>
    </motion.div>
  );
}
