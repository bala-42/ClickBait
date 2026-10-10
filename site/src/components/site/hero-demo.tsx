"use client";

import { useEffect, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import { Pause, Play, Share } from "lucide-react";
import { TONES } from "@/lib/site";
import { Triangle } from "./triangle";
import { Keys } from "./bits";
import { MacWindow } from "./window";

type Phase = "idle" | "listening" | "thinking" | "pointing" | "back";

// How long each beat lasts (ms), then it loops.
const BEATS: [Phase, number][] = [
  ["idle", 1400],
  ["listening", 2300],
  ["thinking", 1700],
  ["pointing", 3200],
  ["back", 1000],
];

// Where things sit on the stage, in % of its width and height.
const CURSOR = { idle: { x: 24, y: 56 }, moved: { x: 29, y: 60 } };
const SHARE_TIP = { x: 84, y: 11.2 };

function Arrow() {
  // A plain pointer cursor.
  return (
    <svg width="18" height="26" viewBox="0 0 18 26" aria-hidden="true" className="drop-shadow-[0_2px_3px_rgb(0_0_0/0.6)]">
      <path d="M1.5 1.5 L1.5 20.5 L6.4 15.9 L9.6 23.4 L12.9 22 L9.8 14.7 L16.3 14.7 Z" fill="#fff" stroke="#111" strokeWidth="1.4" strokeLinejoin="round" />
    </svg>
  );
}

function Waveform() {
  return (
    <span className="flex h-3.5 items-center gap-[3px]" aria-hidden="true">
      {[0.5, 1, 0.7, 0.9, 0.4].map((h, i) => (
        <motion.span
          key={i}
          className="w-[3px] rounded-full bg-white"
          animate={{ height: ["30%", `${h * 100}%`, "30%"] }}
          transition={{ duration: 0.6 + i * 0.08, repeat: Infinity, ease: "easeInOut" }}
        />
      ))}
    </span>
  );
}

export function HeroDemo() {
  const reduce = useReducedMotion();
  const [paused, setPaused] = useState(false);
  const [beat, setBeat] = useState(0);
  // With reduced motion: one still frame, the pointing moment.
  const phase: Phase = reduce ? "pointing" : BEATS[beat][0];

  useEffect(() => {
    if (reduce || paused) return;
    const timer = setTimeout(() => setBeat((b) => (b + 1) % BEATS.length), BEATS[beat][1]);
    return () => clearTimeout(timer);
  }, [beat, paused, reduce]);

  const cursor = phase === "idle" ? CURSOR.idle : CURSOR.moved;
  const pointing = phase === "pointing";
  const tone = phase === "listening" || phase === "thinking" ? "pumpkin" : "azure";
  // Beside the cursor, or with its tip on the Share button.
  const triangle = pointing ? SHARE_TIP : { x: cursor.x + 1.8, y: cursor.y + 5.5 };

  return (
    <div className="relative">
      <MacWindow title="Lisbon trip — Notes" bodyClassName="aspect-[4/3] sm:aspect-[16/10] select-none">
        <p className="sr-only">
          Demo: someone holds Control and Option and asks “how do I share this?”. The ClickBait triangle turns orange while it
          listens and thinks, then turns blue and glides to the Share button with a label saying “Share’s up here!”.
        </p>
        {/* The pretend app. */}
        <div aria-hidden="true" className="absolute inset-0 bg-[linear-gradient(180deg,#1b1b23,#15151c)]">
          <div className="flex h-[13%] items-center justify-between border-b border-white/[0.06] px-[4%]">
            <div className="flex gap-2">
              {[0, 1, 2].map((i) => (
                <span key={i} className="h-2.5 w-6 rounded-full bg-white/[0.07] sm:w-9" />
              ))}
            </div>
            <span
              className="flex items-center gap-1.5 rounded-md border px-2 py-1 text-[10px] font-medium text-white/80 transition-colors duration-500 sm:px-2.5 sm:text-xs"
              style={{
                borderColor: pointing ? TONES.azure.hex : "rgb(255 255 255 / 0.1)",
                background: pointing ? "rgb(0 127 255 / 0.18)" : "rgb(255 255 255 / 0.04)",
              }}
            >
              <Share className="size-3" /> Share
            </span>
          </div>
          <div className="space-y-[3.5%] px-[6%] pt-[5%]">
            <div className="h-[0.9rem] w-1/3 rounded bg-white/15 sm:h-5" />
            <div className="h-2 w-5/6 rounded bg-white/[0.07]" />
            <div className="h-2 w-2/3 rounded bg-white/[0.07]" />
            <div className="flex gap-[4%] pt-[2%]">
              <div className="aspect-[4/3] w-[38%] rounded-lg bg-[radial-gradient(circle_at_30%_30%,#ffb36b,#ff7518_45%,#7a2e8f)] opacity-80" />
              <div className="flex-1 space-y-3 pt-1">
                <div className="h-2 w-full rounded bg-white/[0.07]" />
                <div className="h-2 w-4/5 rounded bg-white/[0.07]" />
                <div className="h-2 w-11/12 rounded bg-white/[0.07]" />
                <div className="h-2 w-3/5 rounded bg-white/[0.07]" />
              </div>
            </div>
          </div>
        </div>

        {/* The visitor's pretend cursor. */}
        <motion.div
          aria-hidden="true"
          className="absolute z-10"
          initial={false}
          animate={{ left: `${cursor.x}%`, top: `${cursor.y}%` }}
          transition={{ type: "spring", stiffness: 60, damping: 16 }}
        >
          <Arrow />
        </motion.div>

        {/* ClickBait. */}
        <motion.div
          aria-hidden="true"
          className="absolute z-20"
          style={{ marginLeft: -2, marginTop: -2 }}
          initial={false}
          animate={{ left: `${triangle.x}%`, top: `${triangle.y}%` }}
          transition={pointing ? { type: "spring", stiffness: 70, damping: 15 } : { type: "spring", stiffness: 140, damping: 18 }}
        >
          <Triangle tone={tone} size={26} spinning={phase === "thinking"} pulsing={pointing} rotate={0} />
          <AnimatePresence mode="wait">
            {phase !== "idle" && phase !== "back" && (
              <motion.div
                key={phase}
                initial={{ opacity: 0, y: 4, scale: 0.95 }}
                animate={{ opacity: 1, y: 0, scale: 1 }}
                exit={{ opacity: 0, scale: 0.95 }}
                transition={{ duration: 0.25 }}
                className={`absolute top-7 flex items-center gap-2 whitespace-nowrap rounded-full px-3 py-1.5 text-xs font-semibold text-white shadow-lg sm:text-[13px] ${pointing ? "right-0" : "left-5"}`}
                style={{ background: TONES[tone].hex, boxShadow: `0 0 20px ${TONES[tone].hex}77` }}
              >
                {phase === "listening" && (
                  <>
                    <Waveform /> Listening…
                  </>
                )}
                {phase === "thinking" && <>“how do I share this?”</>}
                {pointing && <>Share’s up here!</>}
              </motion.div>
            )}
          </AnimatePresence>
        </motion.div>

        {/* The keys being held. */}
        <AnimatePresence>
          {phase === "listening" && (
            <motion.div
              aria-hidden="true"
              initial={{ opacity: 0, y: 8 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 8 }}
              className="absolute bottom-[6%] left-1/2 z-30 flex -translate-x-1/2 items-center gap-2 rounded-xl border border-white/10 bg-black/60 px-3 py-2 text-xs text-white/80 backdrop-blur"
            >
              holding <Keys keys={["⌃", "⌥"]} />
            </motion.div>
          )}
        </AnimatePresence>
      </MacWindow>

      {!reduce && (
        <button
          type="button"
          onClick={() => setPaused((p) => !p)}
          className="absolute bottom-3 right-3 z-40 flex size-8 items-center justify-center rounded-full border border-white/15 bg-black/60 text-white/80 backdrop-blur transition hover:text-white"
          aria-label={paused ? "Play the demo" : "Pause the demo"}
        >
          {paused ? <Play className="size-3.5" /> : <Pause className="size-3.5" />}
        </button>
      )}
    </div>
  );
}
