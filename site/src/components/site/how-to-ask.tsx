import { ArrowUp, Copy, X } from "lucide-react";
import { TONES, type Tone } from "@/lib/site";
import { BaitHeading, Em, Keys, Pill, Section } from "./bits";
import { Triangle } from "./triangle";

const WAYS: { keys: string[]; how: string; what: string; example?: string; tone: Tone }[] = [
  { keys: ["⌃", "⌥"], how: "Hold and talk", what: "Ask anything out loud. Let go when you’re done.", example: "“show me the share button”", tone: "pumpkin" },
  { keys: ["⌥", "⌘"], how: "Tap", what: "Explains the text you’ve highlighted, in plain words.", tone: "pumpkin" },
  { keys: ["⌥", "⌘"], how: "Hold and draw", what: "Circle or box anything on screen to get it explained.", tone: "strawberry" },
  { keys: ["⌥", "⌘", "⌥", "⌘"], how: "Double-tap", what: "Type instead of talking. Or hold ⌥⌘ and right-click.", tone: "azure" },
  { keys: ["esc"], how: "Press", what: "Stops whatever it’s doing. Instantly.", tone: "azure" },
];

function ChatPanel() {
  return (
    <div className="glass relative w-full max-w-md rounded-[28px] p-5 text-left" role="img" aria-label="ClickBait’s chat panel answering “how do I VLOOKUP in Excel?” with a short explanation and a formula with a Copy button.">
      <div aria-hidden="true">
        <div className="flex items-center justify-between">
          <span className="flex items-center gap-2 text-sm font-semibold text-white/80">
            <Triangle tone="azure" size={14} /> ClickBait
          </span>
          <span className="flex size-6 items-center justify-center rounded-full bg-white/10">
            <X className="size-3.5 text-white/70" />
          </span>
        </div>
        <p className="mt-4 text-[13px] font-semibold text-white/60">how do I VLOOKUP in Excel?</p>
        <p className="mt-1.5 text-[15px] leading-relaxed text-white">
          VLOOKUP finds a value in the first column of a table and returns a value from the same row in another column.
        </p>
        <div className="mt-3 rounded-xl bg-black/50 p-3 font-mono text-[13px]">
          <div className="mb-1 flex items-center justify-between text-[11px] text-white/45">
            excel
            <span className="flex items-center gap-1 text-white/70">
              <Copy className="size-3" /> Copy
            </span>
          </div>
          <span className="text-white/90">=VLOOKUP(A2, B2:D100, 3, FALSE)</span>
        </div>
        <p className="mt-4 text-[13px] font-semibold text-white/60">what does FALSE do?</p>
        <p className="mt-1.5 text-[15px] leading-relaxed text-white">
          It asks for an <strong>exact</strong> match, so Excel won’t return the nearest value when the lookup value is missing.
        </p>
        <div className="mt-4 flex items-center justify-between rounded-2xl bg-white/[0.07] px-4 py-3 text-sm text-white/50">
          Ask a follow-up…
          <span className="flex size-6 items-center justify-center rounded-full bg-white/15">
            <ArrowUp className="size-3.5 text-white/60" />
          </span>
        </div>
      </div>
    </div>
  );
}

export function HowToAsk() {
  return (
    <Section id="ask" tone="azure" labelledBy="ask-title">
      <BaitHeading id="ask-title" tone="azure" kicker="How to ask" bait="Doctors hate these 5 keyboard shortcuts">
        Five ways to ask. <Em className="text-azure-text">No menus</Em> to learn.
      </BaitHeading>

      <ol className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        {WAYS.map((way) => (
          <li
            key={way.how}
            className="group relative flex flex-col rounded-2xl border border-white/[0.08] bg-white/[0.025] p-5 transition hover:border-white/15 hover:bg-white/[0.04]"
          >
            <Keys keys={way.keys} className="flex-wrap" />
            <p className="mt-5 text-sm font-semibold" style={{ color: TONES[way.tone].text }}>
              {way.how}
            </p>
            <p className="mt-1 text-[15px] leading-snug text-white/85">{way.what}</p>
            {way.example && <p className="mt-3 text-sm italic text-muted-foreground">{way.example}</p>}
          </li>
        ))}
      </ol>

      <div className="mt-24 grid items-center gap-12 lg:grid-cols-2">
        <div>
          <h3 className="text-balance text-2xl font-semibold tracking-tight sm:text-4xl">
            Short answers pop up. <span className="text-muted-foreground">Long ones open a chat.</span>
          </h3>
          <p className="mt-4 max-w-md text-lg leading-relaxed text-muted-foreground">
            A quick answer is a little pill right by the triangle. Explanations, steps and code open a chat that grows out of the
            triangle, with a Copy button for anything worth copying. Keep asking follow-ups: it remembers until you close it.
          </p>
          <div className="mt-8 flex items-center gap-2" role="img" aria-label="A short answer pill reading “Yep, it’s on!” beside the blue triangle.">
            <Triangle tone="azure" size={22} />
            <Pill tone="azure">Yep, it’s on!</Pill>
          </div>
        </div>
        <div className="relative flex justify-center lg:justify-end">
          <div aria-hidden="true" className="absolute inset-10 -z-10 rounded-full bg-azure/20 blur-[90px]" />
          <ChatPanel />
        </div>
      </div>
    </Section>
  );
}
