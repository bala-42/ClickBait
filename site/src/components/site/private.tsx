import { HardDrive, Heart, EyeOff } from "lucide-react";
import { GITHUB_URL, MODEL } from "@/lib/site";
import { BaitHeading, Em, Section, Sticker } from "./bits";

const TILES = [
  {
    icon: HardDrive,
    title: "It all runs on your Mac",
    body: `Answers come from a local AI model (${MODEL}, through Ollama). Your voice is turned into text on your Mac by WhisperKit. Once it’s set up, it works offline.`,
  },
  {
    icon: EyeOff,
    title: "Nobody’s watching",
    body: "No account, no server, no telemetry. Screenshots aren’t kept, and it won’t even look while a password manager is in front.",
  },
  {
    icon: Heart,
    title: "Free. Properly free.",
    body: "Open source under the Apache 2.0 licence. No plans, no trial, no “pro”. Read every line of it.",
  },
];

export function Private() {
  return (
    <Section id="open" tone="azure" labelledBy="open-title" className="overflow-hidden">
      <div aria-hidden="true" className="pointer-events-none absolute left-1/2 top-1/3 -z-10 size-[600px] -translate-x-1/2 rounded-full bg-azure/10 blur-[140px]" />
      <BaitHeading id="open-title" tone="azure" kicker="Private and open source" bait="This free app is secretly watching your screen">
        Only when you ask. <Em className="text-azure-text">And it never tells anyone.</Em>
      </BaitHeading>

      <div className="relative mt-14 grid gap-4 md:grid-cols-3">
        <Sticker tone="lavender" rotate={8} className="absolute -top-4 right-6 z-10 hidden md:inline-flex">
          works on a plane ✈︎
        </Sticker>
        {TILES.map(({ icon: Icon, title, body }) => (
          <div key={title} className="rounded-3xl border border-white/[0.08] bg-gradient-to-b from-white/[0.05] to-white/[0.01] p-7">
            <Icon className="size-6 text-azure-text" aria-hidden="true" />
            <h3 className="mt-5 text-xl font-semibold tracking-tight">{title}</h3>
            <p className="mt-2 leading-relaxed text-muted-foreground">{body}</p>
          </div>
        ))}
      </div>

      <div className="mt-6 grid gap-6 rounded-3xl border border-pumpkin/25 bg-pumpkin/[0.06] p-7 md:grid-cols-[auto_1fr] md:items-center">
        <p className="font-mono text-xs uppercase tracking-[0.2em] text-pumpkin-text">Honest bit</p>
        <p className="text-lg leading-relaxed text-white/85">
          Being private has one cost: it isn’t instant. Pointing at a button it can name takes a blink. Questions where it has to
          look at your screen take several seconds. <span className="text-muted-foreground">We think your screen is worth the wait.</span>
        </p>
      </div>

      <p className="mt-8 text-muted-foreground">
        Don’t take our word for it:{" "}
        <a href={GITHUB_URL} className="font-medium text-white underline decoration-white/30 underline-offset-4 hover:decoration-white">
          the code’s all on GitHub
        </a>
        .
      </p>
    </Section>
  );
}
