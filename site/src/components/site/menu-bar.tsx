"use client";

import { useSyncExternalStore } from "react";
import { DOWNLOAD_URL } from "@/lib/site";
import { Triangle } from "./triangle";

const LINKS = [
  { href: "#colours", label: "Colours" },
  { href: "#ask", label: "How to ask" },
  { href: "#walkthroughs", label: "Walkthroughs" },
  { href: "#coders", label: "For coders" },
  { href: "#open", label: "Privacy" },
  { href: "#faq", label: "FAQ" },
];

// The time, like a real menu bar: read from the clock, refreshed every 15 s, empty in the
// static HTML (there's no "now" at build time).
const formatNow = () =>
  new Date().toLocaleString("en-GB", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).replace(",", "");
let cachedNow = "";
function subscribe(onChange: () => void) {
  cachedNow = formatNow();
  const timer = setInterval(() => {
    cachedNow = formatNow();
    onChange();
  }, 15_000);
  return () => clearInterval(timer);
}

function Clock() {
  const now = useSyncExternalStore(subscribe, () => cachedNow || formatNow(), () => "");
  return <span className="hidden tabular-nums text-white/70 md:inline">{now}</span>;
}

/** The nav, dressed as a Mac menu bar. */
export function MenuBar() {
  return (
    <header className="sticky top-0 z-50 border-b border-white/[0.06] bg-[#0a0a0f]/70 backdrop-blur-xl">
      <nav aria-label="Main" className="mx-auto flex h-12 max-w-6xl items-center gap-5 px-4 text-[13px] sm:px-6">
        <a href="#top" className="flex items-center gap-2 font-semibold" data-quip="that’s me!">
          <Triangle tone="azure" size={16} />
          ClickBait
        </a>
        <ul className="hidden items-center gap-5 text-white/70 lg:flex">
          {LINKS.map((link) => (
            <li key={link.href}>
              <a href={link.href} className="transition-colors hover:text-white">
                {link.label}
              </a>
            </li>
          ))}
        </ul>
        <div className="ml-auto flex items-center gap-4">
          <Clock />
          <a
            href={DOWNLOAD_URL}
            data-quip="ooh, yes please"
            className="rounded-full bg-white px-3.5 py-1.5 text-[13px] font-semibold text-black transition hover:bg-white/90"
          >
            Download
          </a>
        </div>
      </nav>
    </header>
  );
}
