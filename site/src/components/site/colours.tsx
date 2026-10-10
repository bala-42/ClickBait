"use client";

import { useState } from "react";
import { AnimatePresence, motion } from "motion/react";
import { ContinuousTabs } from "@/components/watermelon/continuous-tabs";
import { TONES, type Tone } from "@/lib/site";
import { BaitHeading, Keys, Section } from "./bits";
import { Triangle } from "./triangle";
import { VideoFrame } from "./video-frame";

const STATES: { tone: Tone; label: string; title: string; body: React.ReactNode; shot: string; window: string }[] = [
  {
    tone: "azure",
    label: "Pointing",
    title: "Blue: here to help",
    body: "Following your cursor, or pointing at the thing you asked about. If it can name the button on screen, it points almost instantly.",
    shot: "Ask “where’s the share button?” in Pages. The triangle glides over and points at Share, with a little “Share’s up here!” label.",
    window: "Pages",
  },
  {
    tone: "pumpkin",
    label: "Thinking",
    title: "Orange: all ears, then thinking",
    body: (
      <>
        Hold <Keys keys={["⌃", "⌥"]} className="align-middle" /> and it listens. Let go and it thinks, turning a third at a time like a tiny cog.
      </>
    ),
    shot: "Hold Control+Option and ask a question. The waveform shows while you talk, then the orange triangle ticks round while it thinks.",
    window: "Safari",
  },
  {
    tone: "shamrock",
    label: "Doing",
    title: "Green: on it",
    body: "Things you ask your Mac to do: opening apps, tidying files, making notes and reminders. Anything risky asks first.",
    shot: "Select three files in Finder and say “compress these”. The triangle goes green, “Compressing…”, then “Compressed 3 items into Archive.zip”.",
    window: "Finder",
  },
  {
    tone: "strawberry",
    label: "Circling",
    title: "Red: circling something",
    body: (
      <>
        Hold <Keys keys={["⌥", "⌘"]} className="align-middle" /> and draw round anything. Red means it’s snipping, and it stays red while it tours the parts.
      </>
    ),
    shot: "Hold Option+Command and circle an unlabelled solar-system picture. The explanation appears, then red “~ jupiter” pills tour the planets.",
    window: "Preview",
  },
  {
    tone: "lavender",
    label: "Walkthroughs",
    title: "Lavender: walking you through it",
    body: "Ask how to do something and it points at each click in turn, ticking off a checklist. You do the clicking.",
    shot: "Ask “how do I clear my history?” in Safari. Click “show me!”, then follow the lavender triangle: History menu, Clear History…, Clear History, ✓.",
    window: "Safari",
  },
];

export function Colours() {
  const [active, setActive] = useState<Tone>("azure");
  const state = STATES.find((s) => s.tone === active) ?? STATES[0];

  return (
    <Section id="colours" tone="pumpkin" labelledBy="colours-title">
      <BaitHeading id="colours-title" tone="pumpkin" kicker="Five colours" bait="This triangle changes colour 5 times. Number 4 will shock you.">
        It changes colour so you always know what it’s up to.
      </BaitHeading>

      <div className="mt-12 flex justify-center sm:justify-start">
        <ContinuousTabs
          label="ClickBait’s colours"
          idPrefix="tone"
          active={active}
          onChange={(id) => setActive(id as Tone)}
          tabs={STATES.map((s) => ({ id: s.tone, label: s.label, colour: TONES[s.tone].hex }))}
        />
      </div>

      <div
        id={`tone-panel-${state.tone}`}
        role="tabpanel"
        aria-labelledby={`tone-tab-${state.tone}`}
        tabIndex={0}
        className="mt-10 grid items-center gap-10 rounded-3xl outline-none lg:grid-cols-[2fr_3fr]"
      >
        <AnimatePresence mode="wait">
          <motion.div
            key={state.tone}
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -10 }}
            transition={{ duration: 0.25 }}
          >
            <div className="flex items-center gap-3">
              <Triangle tone={state.tone} size={30} spinning={state.tone === "pumpkin"} pulsing={state.tone !== "pumpkin"} />
              <span className="font-mono text-sm" style={{ color: TONES[state.tone].text }}>
                {TONES[state.tone].name} · {TONES[state.tone].hex}
              </span>
            </div>
            <h3 className="mt-5 text-2xl font-semibold tracking-tight sm:text-3xl">{state.title}</h3>
            <p className="mt-3 text-lg leading-relaxed text-muted-foreground">{state.body}</p>
          </motion.div>
        </AnimatePresence>
        <VideoFrame title={state.window} tone={state.tone} shot={state.shot} />
      </div>
    </Section>
  );
}
