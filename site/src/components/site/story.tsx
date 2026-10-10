import { Em, Section } from "./bits";
import { Triangle } from "./triangle";

/** The story slot (where a landing page would put testimonials: there are none to show yet). */
export function Story() {
  return (
    <Section id="story" tone="lavender" labelledBy="story-title">
      <div className="mx-auto max-w-3xl text-center">
        <div className="flex justify-center gap-3" aria-hidden="true">
          <Triangle tone="azure" size={20} />
          <Triangle tone="pumpkin" size={20} />
          <Triangle tone="shamrock" size={20} />
          <Triangle tone="strawberry" size={20} />
          <Triangle tone="lavender" size={20} />
        </div>
        <h2 id="story-title" className="mt-8 text-balance text-3xl font-semibold tracking-tight sm:text-5xl">
          Why a <Em className="text-lavender-text">triangle?</Em>
        </h2>
        <div className="mt-8 space-y-5 text-pretty text-lg leading-relaxed text-muted-foreground sm:text-xl">
          <p>
            Most help on a computer is a wall of text telling you where to click. We wanted something that just…{" "}
            <span className="text-white">points.</span> And we didn’t fancy sending our screens to someone else’s server to get it.
          </p>
          <p>
            So ClickBait runs on your Mac, costs nothing, and keeps its code out in the open. A triangle, because it’s the
            shape of a pointer with nothing to prove.
          </p>
          <p className="text-white/85">
            It’s a friends beta, so it’ll get things wrong sometimes. When it does, tell us. That’s the deal.
          </p>
        </div>
      </div>
    </Section>
  );
}
