import { InlineToast } from "@/components/watermelon/inline-toast";
import { MODEL, MODEL_SIZE } from "@/lib/site";
import { BaitHeading, Em, Section } from "./bits";

export function Setup() {
  return (
    <Section id="setup" tone="shamrock" labelledBy="setup-title">
      <BaitHeading id="setup-title" tone="shamrock" kicker="Setup" bait="Set it up in 30 seconds with this one weird trick">
        Three steps. <Em className="text-shamrock-text">One big download.</Em>
      </BaitHeading>

      <ol className="mt-14 grid gap-4 lg:grid-cols-3">
        <li className="rounded-3xl border border-white/[0.08] bg-white/[0.025] p-7">
          <p className="font-mono text-sm text-shamrock-text">01</p>
          <h3 className="mt-3 text-xl font-semibold">Install Ollama</h3>
          <p className="mt-2 leading-relaxed text-muted-foreground">
            It’s the free app that runs AI models on your Mac. Get it from{" "}
            <a href="https://ollama.com/download" className="font-medium text-white underline decoration-white/30 underline-offset-4 hover:decoration-white">
              ollama.com
            </a>
            .
          </p>
        </li>
        <li className="min-w-0 rounded-3xl border border-white/[0.08] bg-white/[0.025] p-6 sm:p-7">
          <p className="font-mono text-sm text-shamrock-text">02</p>
          <h3 className="mt-3 text-xl font-semibold">Download the brain</h3>
          <p className="mt-2 leading-relaxed text-muted-foreground">
            Paste this into Terminal. It’s about {MODEL_SIZE}, so maybe put the kettle on.
          </p>
          <div className="mt-5">
            <InlineToast code={`ollama pull ${MODEL}`} />
          </div>
        </li>
        <li className="rounded-3xl border border-white/[0.08] bg-white/[0.025] p-7">
          <p className="font-mono text-sm text-shamrock-text">03</p>
          <h3 className="mt-3 text-xl font-semibold">Open ClickBait</h3>
          <p className="mt-2 leading-relaxed text-muted-foreground">
            Allow the microphone, Screen Recording and Accessibility, then download the speech model once when it asks. That’s
            it: hold ⌃⌥ and say hello.
          </p>
        </li>
      </ol>

      <div className="mt-6 rounded-3xl border border-white/[0.08] p-7">
        <h3 className="font-semibold">You’ll need</h3>
        <ul className="mt-4 grid gap-x-8 gap-y-2 text-muted-foreground sm:grid-cols-2 lg:grid-cols-4">
          <li>A Mac with Apple Silicon (M1 or later)</li>
          <li>macOS 14 Sonoma or later</li>
          <li>16 GB of memory (24 GB recommended)</li>
          <li>About 10 GB of free space</li>
        </ul>
      </div>
    </Section>
  );
}
