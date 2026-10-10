"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import { TONES } from "@/lib/site";
import { BaitHeading, Em, Keys, Section } from "./bits";
import { MacWindow } from "./window";
import { Triangle } from "./triangle";

// An original little solar system (viewBox 400 × 250): name, x, y, radius, colour.
const PLANETS: [string, number, number, number, string][] = [
  ["mercury", 96, 186, 5, "#b9a99a"],
  ["venus", 128, 168, 8, "#e0b27a"],
  ["earth", 164, 148, 9, "#4f8fe0"],
  ["mars", 196, 126, 7, "#d0603e"],
  ["jupiter", 246, 132, 20, "#d9a36f"],
  ["saturn", 302, 96, 14, "#e8cf96"],
  ["uranus", 342, 70, 11, "#8fd3df"],
  ["neptune", 372, 48, 10, "#4d6fe0"],
];
// Tour stops: the bigger ones first, like the app's tour of named parts.
const TOUR = ["jupiter", "saturn", "earth", "neptune"];

function SolarSystem({ phase, stop }: { phase: "idle" | "circling" | "touring"; stop: number }) {
  const current = phase === "touring" ? PLANETS.find((p) => p[0] === TOUR[stop]) : undefined;
  return (
    <MacWindow title="solar-system.png — Preview" bodyClassName="aspect-[16/10]">
      <p className="sr-only">
        Demo: a hand-drawn red loop circles a picture of the solar system, then the red triangle tours the planets with labels
        like “~ jupiter” and “~ saturn”.
      </p>
      <svg viewBox="0 0 400 250" className="absolute inset-0 size-full" aria-hidden="true">
        <defs>
          <radialGradient id="sun" cx="0" cy="250" r="120" gradientUnits="userSpaceOnUse">
            <stop offset="0" stopColor="#fff4c2" />
            <stop offset="0.4" stopColor="#ffb347" />
            <stop offset="0.62" stopColor="#ff6a1f" />
            <stop offset="0.75" stopColor="#ff5a1f" stopOpacity="0.35" />
            <stop offset="1" stopColor="#ff5a1f" stopOpacity="0" />
          </radialGradient>
        </defs>
        <rect width="400" height="250" fill="#0b0b14" />
        {Array.from({ length: 40 }).map((_, i) => (
          <circle key={i} cx={(i * 97) % 400} cy={(i * 53) % 250} r={(i % 3) * 0.3 + 0.3} fill="#fff" opacity={0.25 + (i % 4) * 0.1} />
        ))}
        <circle cx="0" cy="250" r="120" fill="url(#sun)" />
        {PLANETS.map(([name, x, y], i) => (
          <ellipse key={`o-${name}`} cx="0" cy="250" rx={Math.hypot(x, 250 - y)} ry={Math.hypot(x, 250 - y)} fill="none" stroke="#fff" strokeOpacity={0.07 + i * 0.005} />
        ))}
        {PLANETS.map(([name, x, y, r, colour]) => (
          <g key={name}>
            <circle cx={x} cy={y} r={r} fill={colour} />
            {name === "saturn" && <ellipse cx={x} cy={y} rx={r * 1.9} ry={r * 0.5} fill="none" stroke="#e8cf96" strokeOpacity="0.7" strokeWidth="2.5" transform={`rotate(-18 ${x} ${y})`} />}
          </g>
        ))}
        {/* The loop the user draws. */}
        <motion.path
          d="M72 214 C 46 150, 160 52, 290 26 C 380 8, 410 40, 392 82 C 368 140, 260 178, 160 208 C 120 220, 84 228, 74 214 C 70 206, 74 199, 82 196"
          fill="none"
          stroke={TONES.strawberry.hex}
          strokeWidth="3.5"
          strokeLinecap="round"
          initial={false}
          animate={{ pathLength: phase === "idle" ? 0 : 1, opacity: phase === "idle" ? 0 : 1 }}
          transition={{ pathLength: { duration: phase === "circling" ? 1.4 : 0, ease: "easeInOut" }, opacity: { duration: 0.2 } }}
          style={{ filter: `drop-shadow(0 0 4px ${TONES.strawberry.hex})` }}
        />
      </svg>
      {current && (
        <motion.div
          aria-hidden="true"
          className="absolute z-10"
          initial={false}
          animate={{ left: `${((current[1] + current[3] * 0.6) / 400) * 100}%`, top: `${((current[2] + current[3] * 0.6) / 250) * 100}%` }}
          transition={{ type: "spring", stiffness: 90, damping: 16 }}
          style={{ marginLeft: -2, marginTop: -2 }}
        >
          <Triangle tone="strawberry" size={22} pulsing />
          <AnimatePresence mode="wait">
            <motion.span
              key={current[0]}
              initial={{ opacity: 0, scale: 0.9 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0 }}
              className="absolute left-5 top-5 whitespace-nowrap rounded-full px-2.5 py-1 text-center text-xs font-semibold text-white"
              style={{ background: TONES.strawberry.hex, boxShadow: `0 0 16px ${TONES.strawberry.hex}88` }}
            >
              ~ {current[0]}
            </motion.span>
          </AnimatePresence>
        </motion.div>
      )}
    </MacWindow>
  );
}

export function CircleAnything() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { margin: "-20% 0px" });
  const [tick, setTick] = useState(0);
  // 0 idle, 1 circling, 2..5 touring each stop.
  const step = reduce ? 2 : tick;
  const phase = step === 0 ? "idle" : step === 1 ? "circling" : "touring";

  useEffect(() => {
    if (reduce || !inView) return;
    const timer = setTimeout(() => setTick((t) => (t + 1) % (TOUR.length + 2)), tick === 0 ? 900 : tick === 1 ? 2000 : 1700);
    return () => clearTimeout(timer);
  }, [tick, inView, reduce]);

  return (
    <Section id="circle" tone="strawberry" labelledBy="circle-title">
      <div ref={ref} className="grid items-center gap-12 lg:grid-cols-2">
        <div>
          <BaitHeading id="circle-title" tone="strawberry" kicker="Circle anything" bait="Scientists can’t explain this one picture">
            ClickBait can. <Em className="text-strawberry-text">Just circle it.</Em>
          </BaitHeading>
          <p className="mt-6 max-w-lg text-lg leading-relaxed text-muted-foreground">
            Hold <Keys keys={["⌥", "⌘"]} className="align-middle" /> and draw round a chart, a diagram, a photo or a bit of code. You get a
            plain-English explanation in the chat.
          </p>
          <p className="mt-4 max-w-lg text-lg leading-relaxed text-muted-foreground">
            On pictures without labels, it tours the parts with red <span className="font-semibold text-strawberry-text">~ name</span> pills.
            It finds the actual things (and faces) in the picture on your Mac first, so the pills land on real things. The{" "}
            <span className="font-semibold text-white">~</span> is honesty: the names are its best guess.
          </p>
        </div>
        <SolarSystem phase={phase} stop={Math.max(0, step - 2)} />
      </div>
    </Section>
  );
}
