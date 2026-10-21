import { ArrowDownToLine } from "lucide-react";
import { FaGithub } from "react-icons/fa6";
import { ShimmerLink } from "@/components/watermelon/shimmer-button";
import { DOWNLOAD_URL, GITHUB_URL } from "@/lib/site";
import { Em } from "./bits";
import { Triangle } from "./triangle";

export function Footer() {
  return (
    <footer data-tone="azure" className="relative overflow-hidden px-4 pb-10 pt-24 sm:px-6 sm:pt-32">
      <div aria-hidden="true" className="pointer-events-none absolute inset-x-0 bottom-0 -z-10 h-[420px] bg-[radial-gradient(60%_80%_at_50%_100%,rgb(0_127_255/0.25),transparent)]" />
      <div className="mx-auto max-w-6xl">
        <div className="mx-auto max-w-2xl text-center">
          <Triangle tone="azure" size={44} pulsing className="mx-auto" />
          <h2 className="mt-8 text-balance text-4xl font-semibold tracking-tight sm:text-6xl">
            Go on. <Em className="text-azure-text">Click it.</Em>
          </h2>
          <p className="mt-4 text-lg text-muted-foreground">It’s the only clickbait that actually delivers.</p>
          <div className="mt-8 flex justify-center">
            <ShimmerLink
              href={DOWNLOAD_URL}
              shineClassName="via-azure/25"
              data-quip="you know you want to"
              className="rounded-xl bg-white px-6 py-3.5 text-base font-semibold text-black shadow-[0_0_40px_-8px_rgb(0_127_255/0.8)]"
            >
              <ArrowDownToLine className="size-4" aria-hidden="true" />
              Download for Mac
            </ShimmerLink>
          </div>
          <p className="mt-4 text-xs text-muted-foreground">Free · Apple Silicon · macOS 14 or later</p>
        </div>

        <div className="mt-24 flex flex-col items-center justify-between gap-6 border-t border-white/[0.07] pt-8 text-sm text-muted-foreground sm:flex-row">
          <p className="flex items-center gap-2">
            <Triangle tone="azure" size={14} /> ClickBait · AGPL-3.0 licence
          </p>
          <p>No cookies, no trackers. Not even on this page.</p>
          <a href={GITHUB_URL} className="flex items-center gap-2 font-medium text-white/85 transition hover:text-white">
            <FaGithub className="size-4" aria-hidden="true" />
            GitHub
          </a>
        </div>
      </div>
    </footer>
  );
}
