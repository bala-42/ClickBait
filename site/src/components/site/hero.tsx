import { ArrowDownToLine } from "lucide-react";
import { FaGithub } from "react-icons/fa6";
import { ShimmerLink } from "@/components/watermelon/shimmer-button";
import { DOWNLOAD_URL, GITHUB_URL } from "@/lib/site";
import { Em, Sticker } from "./bits";
import { HeroDemo } from "./hero-demo";

export function Hero() {
  return (
    <section id="top" data-tone="azure" aria-labelledby="hero-title" className="relative overflow-hidden px-4 pb-20 pt-16 sm:px-6 sm:pb-28 sm:pt-24">
      {/* The five colours, glowing behind everything like a wallpaper. */}
      <div aria-hidden="true" className="pointer-events-none absolute inset-0 -z-10">
        <div className="absolute -left-40 top-10 size-[480px] rounded-full bg-azure/25 blur-[120px]" />
        <div className="absolute right-[-10rem] top-40 size-[420px] rounded-full bg-lavender/20 blur-[120px]" />
        <div className="absolute bottom-0 left-1/3 size-[380px] rounded-full bg-pumpkin/15 blur-[120px]" />
      </div>

      <div className="mx-auto max-w-6xl">
        <div className="mx-auto max-w-3xl text-center">
          <p className="mx-auto mb-7 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/[0.04] px-3.5 py-1.5 text-xs font-medium text-white/80">
            <span className="size-1.5 rounded-full bg-shamrock shadow-[0_0_8px_#009E61]" aria-hidden="true" />
            Friends beta · free and open source
          </p>
          <h1 id="hero-title" className="text-balance text-5xl font-semibold leading-[1.02] tracking-tight sm:text-7xl">
            The only clickbait worth <Em className="text-azure-text">following.</Em>
          </h1>
          <p className="mx-auto mt-6 max-w-xl text-pretty text-lg text-muted-foreground sm:text-xl">
            A tiny triangle that lives by your cursor. Ask your Mac anything out loud: it looks at your screen, answers, and{" "}
            <span className="text-foreground">points at exactly what to click.</span>
          </p>

          <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <ShimmerLink
              href={DOWNLOAD_URL}
              shineClassName="via-azure/25"
              data-quip="go on, click it"
              className="rounded-xl bg-white px-6 py-3.5 text-base font-semibold text-black shadow-[0_0_40px_-8px_rgb(0_127_255/0.8)]"
            >
              <ArrowDownToLine className="size-4" aria-hidden="true" />
              Download for Mac
            </ShimmerLink>
            <a
              href={GITHUB_URL}
              data-quip="nothing to hide"
              className="flex items-center gap-2 rounded-xl border border-white/12 bg-white/[0.04] px-5 py-3.5 text-base font-medium text-white/90 transition hover:bg-white/[0.08]"
            >
              <FaGithub className="size-4" aria-hidden="true" />
              Read the code
            </a>
          </div>
          <p className="mt-5 text-xs text-muted-foreground">
            Free forever · Apple Silicon · macOS 14 or later · 16 GB memory (24 GB recommended)
          </p>
        </div>

        <div className="relative mx-auto mt-16 max-w-4xl sm:mt-20">
          <Sticker tone="pumpkin" rotate={-8} className="absolute -top-8 left-2 z-10 sm:-left-8 sm:-top-5">
            no cloud ☁︎✕
          </Sticker>
          <Sticker tone="shamrock" rotate={7} className="absolute -right-2 -top-3 z-10 hidden sm:-right-6 sm:inline-flex">
            £0.00 forever
          </Sticker>
          <HeroDemo />
        </div>
      </div>
    </section>
  );
}
