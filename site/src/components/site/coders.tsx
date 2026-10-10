"use client";

import { useEffect, useRef, useState } from "react";
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react";
import { ArrowUp, Copy, X } from "lucide-react";
import { TONES } from "@/lib/site";
import { BaitHeading, Em, Keys, Section } from "./bits";
import { MacWindow } from "./window";
import { Triangle } from "./triangle";

// Beats: 0 the error, 1 it gets highlighted, 2 ⌥⌘ tapped and ClickBait explains, 3 the answer.
const DURATIONS = [1300, 1300, 1900, 4200];

function TerminalMock({ beat }: { beat: number }) {
  const selected = beat >= 1;
  return (
    <MacWindow title="report.py — Terminal" bodyClassName="min-h-[15rem] sm:min-h-[17rem]">
      <p className="sr-only">
        Demo: a Python error in Terminal, “ZeroDivisionError: division by zero”, is highlighted. Option and Command are tapped, and
        the orange triangle explains it.
      </p>
      <div aria-hidden="true" className="p-4 font-mono text-[11px] leading-relaxed text-white/75 sm:p-5 sm:text-[13px]">
        <p>
          <span className="text-shamrock-text">~/shop</span> <span className="text-white/45">$</span> python3 report.py
        </p>
        <p className="mt-1 text-white/55">Traceback (most recent call last):</p>
        <p className="text-white/55">{"  "}File &quot;report.py&quot;, line 12, in &lt;module&gt;</p>
        <p className="text-white/80">{"    "}total = sum(prices) / len(prices)</p>
        <p className="relative mt-0.5 inline-block">
          <motion.span
            className="absolute inset-y-[-1px] left-[-3px] rounded-sm bg-[#3d6fd9]/70"
            initial={false}
            animate={{ width: selected ? "calc(100% + 6px)" : "0%" }}
            transition={{ duration: selected ? 0.7 : 0, ease: "easeInOut" }}
          />
          <span className={`relative transition-colors duration-500 ${selected ? "text-white" : "text-strawberry-text"}`}>ZeroDivisionError: division by zero</span>
        </p>
        <p className="mt-1">
          <span className="text-shamrock-text">~/shop</span> <span className="text-white/45">$</span>{" "}
          <span className="inline-block h-3.5 w-1.5 translate-y-0.5 bg-white/70" />
        </p>
      </div>

      {/* The keys, then ClickBait explaining by the selection. */}
      <AnimatePresence>
        {beat === 2 && (
          <motion.div
            aria-hidden="true"
            initial={{ opacity: 0, y: 6 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0 }}
            className="absolute bottom-4 left-1/2 flex -translate-x-1/2 items-center gap-2 rounded-xl border border-white/10 bg-black/60 px-3 py-2 text-xs text-white/80 backdrop-blur"
          >
            tap <Keys keys={["⌥", "⌘"]} />
          </motion.div>
        )}
      </AnimatePresence>
      <motion.div
        aria-hidden="true"
        className="absolute right-[8%] top-[52%] flex items-start gap-1.5 sm:right-[14%]"
        initial={false}
        animate={{ opacity: beat >= 2 ? 1 : 0 }}
      >
        <Triangle tone={beat === 2 ? "pumpkin" : "azure"} size={22} spinning={beat === 2} />
        {beat === 2 && (
          <span
            className="mt-4 whitespace-nowrap rounded-full px-2.5 py-1 text-[11px] font-semibold text-white sm:text-xs"
            style={{ background: TONES.pumpkin.hex, boxShadow: `0 0 16px ${TONES.pumpkin.hex}88` }}
          >
            Explaining…
          </span>
        )}
      </motion.div>
    </MacWindow>
  );
}

function AnswerPanel({ shown }: { shown: boolean }) {
  return (
    <motion.div
      className="glass w-full max-w-md rounded-[28px] p-5"
      initial={false}
      animate={{ opacity: shown ? 1 : 0.25, scale: shown ? 1 : 0.97, y: shown ? 0 : 6 }}
      transition={{ type: "spring", stiffness: 200, damping: 24 }}
      role="img"
      aria-label="ClickBait’s chat explaining the error: the list of prices is empty, so Python can’t divide by zero, with a one-line fix and a Copy button."
    >
      <div aria-hidden="true">
        <div className="flex items-center justify-between">
          <span className="flex items-center gap-2 text-sm font-semibold text-white/80">
            <Triangle tone="azure" size={14} /> ClickBait
          </span>
          <span className="flex size-6 items-center justify-center rounded-full bg-white/10">
            <X className="size-3.5 text-white/70" />
          </span>
        </div>
        <p className="mt-4 text-[15px] leading-relaxed text-white">
          Your list of prices is empty, so <code className="font-mono text-[13px]">len(prices)</code> is 0, and Python can’t divide
          by zero. Check there’s something in it first:
        </p>
        <div className="mt-3 rounded-xl bg-black/50 p-3 font-mono text-[12px] sm:text-[13px]">
          <div className="mb-1 flex items-center justify-between text-[11px] text-white/45">
            python
            <span className="flex items-center gap-1 text-white/70">
              <Copy className="size-3" /> Copy
            </span>
          </div>
          <span className="whitespace-pre-wrap text-white/90">{"total = (sum(prices) / len(prices)\n         if prices else 0)"}</span>
        </div>
        <div className="mt-4 flex items-center justify-between rounded-2xl bg-white/[0.07] px-4 py-3 text-sm text-white/50">
          Ask a follow-up…
          <span className="flex size-6 items-center justify-center rounded-full bg-white/15">
            <ArrowUp className="size-3.5 text-white/60" />
          </span>
        </div>
      </div>
    </motion.div>
  );
}

const CARDS: { title: string; body: React.ReactNode }[] = [
  {
    title: "Commands, ready to copy",
    body: (
      <>
        “how do I undo my last commit?” gets{" "}
        <code className="whitespace-nowrap rounded bg-white/10 px-1.5 py-0.5 font-mono text-[13px] text-white">git reset --soft HEAD~1</code> in its
        own block, with a Copy button.
      </>
    ),
  },
  {
    title: "Follow-ups remember",
    body: "“and in JavaScript?” just works. The chat keeps the conversation until you close it.",
  },
  {
    title: "Your code stays put",
    body: "It all runs on your Mac. Your company’s code never goes anywhere, and nobody’s training on it.",
  },
];

export function Coders() {
  const reduce = useReducedMotion();
  const ref = useRef<HTMLDivElement>(null);
  const inView = useInView(ref, { margin: "-20% 0px" });
  const [beat, setBeat] = useState(0);
  const shown = reduce ? 3 : beat;

  useEffect(() => {
    if (reduce || !inView) return;
    const timer = setTimeout(() => setBeat((b) => (b + 1) % DURATIONS.length), DURATIONS[beat]);
    return () => clearTimeout(timer);
  }, [beat, inView, reduce]);

  return (
    <Section id="coders" tone="pumpkin" labelledBy="coders-title">
      <BaitHeading id="coders-title" tone="pumpkin" kicker="For coders" bait="Senior engineers HATE this one weird debugging trick">
        Highlight the error. Tap <Keys keys={["⌥", "⌘"]} className="align-middle" />.{" "}
        <Em className="text-pumpkin-text">Read what went wrong.</Em>
      </BaitHeading>
      <p className="mt-6 max-w-2xl text-lg leading-relaxed text-muted-foreground">
        Select an error, a stack trace or a bit of code you don’t follow, and tap ⌥⌘. ClickBait reads exactly what you selected and
        explains it in plain words, with a fix you can copy.
      </p>

      <div ref={ref} className="mt-12 grid items-center gap-8 lg:grid-cols-[3fr_2fr]">
        <TerminalMock beat={shown} />
        <div className="flex justify-center lg:justify-end">
          <AnswerPanel shown={shown === 3} />
        </div>
      </div>

      <ul className="mt-10 grid gap-4 md:grid-cols-3">
        {CARDS.map(({ title, body }) => (
          <li key={title} className="rounded-2xl border border-white/[0.08] bg-white/[0.025] p-5">
            <p className="font-semibold text-pumpkin-text">{title}</p>
            <p className="mt-1.5 leading-relaxed text-muted-foreground">{body}</p>
          </li>
        ))}
      </ul>

      <div className="mt-8 space-y-2 text-muted-foreground">
        <p>
          <span className="font-semibold text-strawberry-text">Can’t select it?</span> Hold ⌥⌘ and circle it instead: a screenshot of
          code, a video tutorial, a slide.
        </p>
        <p>
          <span className="font-semibold text-white/85">DISCLAIMER:</span> It explains what’s on your screen. It doesn’t read your
          project, run your code or edit your files.
        </p>
      </div>
    </Section>
  );
}
