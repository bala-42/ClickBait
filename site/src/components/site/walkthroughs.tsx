"use client";

import { useEffect, useState } from "react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import { useRef } from "react";
import { Check } from "lucide-react";
import { TONES } from "@/lib/site";
import { BaitHeading, Em, Section } from "./bits";
import { MacWindow } from "./window";
import { Triangle } from "./triangle";

const STEPS = ["Open the History menu", "Choose Clear History…", "Click Clear History"];
// Beat → [where the triangle's tip is (% of stage), its label]
const TARGETS: { x: number; y: number; label: string }[] = [
  { x: 58, y: 62, label: "show me!" },
  { x: 41, y: 9.5, label: "Open the History menu" },
  { x: 47, y: 37, label: "Choose Clear History…" },
  { x: 66.5, y: 74, label: "Click Clear History" },
  { x: 66.5, y: 74, label: "done ✓" },
];
const DURATIONS = [1900, 1700, 1700, 1700, 2200];

function SafariMock({ beat }: { beat: number }) {
  const menuOpen = beat === 2;
  const dialog = beat >= 3;
  const target = TARGETS[beat];
  return (
    <MacWindow title="Safari" bodyClassName="aspect-[4/3] sm:aspect-[16/10]">
      <p className="sr-only">
        Demo: in Safari, the lavender triangle points at the History menu, then at Clear History…, then at the Clear History
        button in the dialog, and finishes with a tick.
      </p>
      <div aria-hidden="true" className="absolute inset-0 bg-[#15151c] text-[10px] sm:text-xs">
        {/* Menu bar */}
        <div className="flex h-[9%] items-center gap-[3.5%] border-b border-white/[0.06] bg-white/[0.03] px-[4%] text-white/70">
          <span className="font-bold text-white/90">Safari</span>
          <span>File</span>
          <span>Edit</span>
          <span>View</span>
          <span className={`rounded px-1.5 py-0.5 ${beat === 1 || menuOpen ? "bg-lavender/30 text-white" : ""}`}>History</span>
          <span className="hidden sm:inline">Bookmarks</span>
          <span className="hidden sm:inline">Window</span>
        </div>
        {/* Page */}
        <div className="space-y-3 p-[6%] opacity-60">
          <div className="mx-auto h-6 w-2/3 rounded-full bg-white/[0.06]" />
          <div className="grid grid-cols-4 gap-3 pt-4">
            {Array.from({ length: 8 }).map((_, i) => (
              <div key={i} className="aspect-square rounded-xl bg-white/[0.05]" />
            ))}
          </div>
        </div>
        {/* History menu */}
        <AnimatePresence>
          {menuOpen && (
            <motion.div
              initial={{ opacity: 0, y: -4 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0 }}
              className="absolute left-[30%] top-[9%] w-[38%] rounded-lg border border-white/10 bg-[#25252f]/95 p-1 text-white/80 shadow-2xl backdrop-blur"
            >
              <div className="rounded px-2 py-1.5">Show All History</div>
              <div className="rounded px-2 py-1.5">Back</div>
              <div className="rounded px-2 py-1.5">Forward</div>
              <div className="my-1 h-px bg-white/10" />
              <div className="rounded bg-lavender/40 px-2 py-1.5 text-white">Clear History…</div>
            </motion.div>
          )}
        </AnimatePresence>
        {/* Dialog */}
        <AnimatePresence>
          {dialog && (
            <motion.div
              initial={{ opacity: 0, scale: 0.96 }}
              animate={{ opacity: beat === 4 ? 0.35 : 1, scale: 1 }}
              exit={{ opacity: 0 }}
              className="absolute left-1/2 top-[38%] w-[52%] -translate-x-1/2 rounded-xl border border-white/10 bg-[#25252f] p-3 text-white/80 shadow-2xl sm:p-4"
            >
              <p className="font-semibold text-white">Clear History</p>
              <p className="mt-1 text-white/60">Clearing history removes cookies and website data.</p>
              <div className="mt-3 flex justify-end gap-2">
                <span className="rounded-md bg-white/10 px-2 py-1">Cancel</span>
                <span className="rounded-md bg-lavender/80 px-2 py-1 font-semibold text-white">Clear History</span>
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
      {/* The companion */}
      <motion.div
        aria-hidden="true"
        className="absolute z-20"
        style={{ marginLeft: -2, marginTop: -2 }}
        initial={false}
        animate={{ left: `${target.x}%`, top: `${target.y}%` }}
        transition={{ type: "spring", stiffness: 90, damping: 16 }}
      >
        <Triangle tone="lavender" size={24} pulsing />
        <AnimatePresence mode="wait">
          <motion.span
            key={target.label}
            initial={{ opacity: 0, x: -4 }}
            animate={{ opacity: 1, x: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.2 }}
            className="absolute left-6 top-5 flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-[11px] font-semibold text-white sm:text-xs"
            style={{ background: TONES.lavender.hex, boxShadow: `0 0 18px ${TONES.lavender.hex}88` }}
          >
            {target.label}
            {beat === 0 && <span className="rounded-full bg-white/25 px-1.5">✕</span>}
          </motion.span>
        </AnimatePresence>
      </motion.div>
    </MacWindow>
  );
}

function Checklist({ beat }: { beat: number }) {
  const done = (i: number) => beat > i + 1 || beat === 4;
  return (
    <div className="glass w-full max-w-sm rounded-[26px] p-5" aria-hidden="true">
      <p className="flex items-center gap-2 text-sm font-semibold text-white/80">
        <Triangle tone="lavender" size={14} /> ClickBait
      </p>
      <p className="mt-3 ml-auto w-fit rounded-2xl bg-azure/30 px-3 py-1.5 text-sm text-white">how do I clear my history?</p>
      <p className="mt-3 text-sm text-white/70">In Safari:</p>
      <ul className="mt-2 space-y-2">
        {STEPS.map((step, i) => (
          <li key={step} className="flex items-center gap-2.5 text-[15px]">
            <span
              className="flex size-5 items-center justify-center rounded-full border transition-colors duration-300"
              style={{
                borderColor: done(i) || beat === i + 1 ? TONES.lavender.hex : "rgb(255 255 255 / 0.2)",
                background: done(i) ? TONES.lavender.hex : "transparent",
              }}
            >
              {done(i) && <Check className="size-3 text-white" strokeWidth={3} />}
            </span>
            <span className={done(i) ? "text-white/50 line-through" : beat === i + 1 ? "text-white" : "text-white/60"}>{step}</span>
          </li>
        ))}
      </ul>
      <AnimatePresence>
        {beat === 4 && (
          <motion.p initial={{ opacity: 0, y: 4 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }} className="mt-4 font-semibold text-lavender-text">
            ✓ Done!
          </motion.p>
        )}
      </AnimatePresence>
    </div>
  );
}

export function Walkthroughs() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { margin: "-20% 0px" });
  const [beat, setBeat] = useState(0);
  const shown = reduce ? 3 : beat;

  useEffect(() => {
    if (reduce || !inView) return;
    const timer = setTimeout(() => setBeat((b) => (b + 1) % TARGETS.length), DURATIONS[beat]);
    return () => clearTimeout(timer);
  }, [beat, inView, reduce]);

  return (
    <Section id="walkthroughs" tone="lavender" labelledBy="walk-title">
      <BaitHeading id="walk-title" tone="lavender" kicker="Walkthroughs" bait="This triangle will do your job for you">
        It won’t. It shows you how, <Em className="text-lavender-text">one click at a time.</Em>
      </BaitHeading>

      <div ref={ref} className="mt-14 grid items-center gap-8 lg:grid-cols-[3fr_2fr]">
        <SafariMock beat={shown} />
        <div className="flex justify-center">
          <Checklist beat={shown} />
        </div>
      </div>

      <ul className="mt-14 grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
        {[
          ["Asks first", "“how do I…?” gets a “show me!” before anything moves. Ignore it and you get the steps written down instead."],
          ["Points, step by step", "Each click gets pointed at in turn, ticked off in a checklist, and finished with a ✓."],
          ["Crosses apps", "If the task lives in another app, it opens or switches to it on the way (that bit’s green)."],
          ["Knows System Settings", "Night Shift, Bluetooth, wallpaper: it knows which page they live on, and points the way."],
        ].map(([title, body]) => (
          <li key={title}>
            <p className="font-semibold text-lavender-text">{title}</p>
            <p className="mt-1.5 leading-relaxed text-muted-foreground">{body}</p>
          </li>
        ))}
      </ul>
      <p className="mt-10 text-lg text-white/85">
        It only points. <span className="text-muted-foreground">You do the clicking: it never clicks for you.</span>
      </p>
    </Section>
  );
}
