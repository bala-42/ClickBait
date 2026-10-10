import { AppWindow, FolderOpen, Globe, NotebookPen, SunMoon } from "lucide-react";
import { TONES } from "@/lib/site";
import { BaitHeading, Em, Section } from "./bits";
import { Triangle } from "./triangle";

const GROUPS = [
  { icon: AppWindow, title: "Apps", says: ["open Safari", "quit Music", "switch to Notes"] },
  { icon: Globe, title: "Websites", says: ["go to YouTube", "take me to Gmail"] },
  { icon: FolderOpen, title: "Finder", says: ["compress these", "rename this to Invoices", "put these in a new folder", "move these to Documents"] },
  { icon: NotebookPen, title: "Notes & reminders", says: ["make a note: plumber on Tuesday", "add this page’s link to my notes", "remind me to water the plants on Friday"] },
  { icon: SunMoon, title: "Your Mac", says: ["dark mode", "volume 30", "next song", "take a screenshot"] },
];

function ConfirmCard() {
  return (
    <div
      role="img"
      aria-label="A green card asking “Move the 3 selected items to the Trash?” with Do it and Cancel buttons."
      className="relative w-full max-w-xs rounded-2xl border p-4 shadow-2xl"
      style={{ borderColor: `${TONES.shamrock.hex}66`, background: `linear-gradient(160deg, ${TONES.shamrock.hex}26, #14141b 60%)` }}
    >
      <div aria-hidden="true">
        <p className="flex items-start gap-2 text-sm font-semibold text-white">
          <Triangle tone="shamrock" size={16} pulsing /> Move the 3 selected items to the Trash?
        </p>
        <div className="mt-4 flex gap-2">
          <span className="rounded-lg px-3 py-1.5 text-sm font-semibold text-white" style={{ background: TONES.shamrock.hex }}>
            Do it
          </span>
          <span className="rounded-lg bg-white/10 px-3 py-1.5 text-sm text-white/80">Cancel</span>
        </div>
        <p className="mt-3 text-xs text-white/60">or just say “yes” · Esc cancels</p>
      </div>
    </div>
  );
}

export function MacActions() {
  return (
    <Section id="actions" tone="shamrock" labelledBy="actions-title">
      <BaitHeading id="actions-title" tone="shamrock" kicker="Mac actions" bait="Say these words and your Mac will obey you">
        Weirdly, that one’s <Em className="text-shamrock-text">true.</Em> Within reason.
      </BaitHeading>
      <p className="mt-6 max-w-2xl text-lg leading-relaxed text-muted-foreground">
        Hold <span className="font-mono text-white/85">⌃⌥</span> and tell your Mac what to do. It turns green and gets on with it. Say it
        your own way and it works out what you meant, but then anything risky (the Trash, moving, renaming, quitting) asks first.
      </p>

      <div className="mt-12 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
        {GROUPS.map(({ icon: Icon, title, says }) => (
          <div key={title} className="rounded-2xl border border-white/[0.08] bg-white/[0.025] p-5">
            <p className="flex items-center gap-2 font-semibold">
              <Icon className="size-4 text-shamrock-text" aria-hidden="true" />
              {title}
            </p>
            <ul className="mt-4 flex flex-wrap gap-2">
              {says.map((say) => (
                <li key={say} className="rounded-full border border-shamrock/30 bg-shamrock/10 px-3 py-1 text-sm text-white/90">
                  “{say}”
                </li>
              ))}
            </ul>
          </div>
        ))}
        <div className="flex items-center justify-center rounded-2xl border border-dashed border-white/10 p-5">
          <ConfirmCard />
        </div>
      </div>
    </Section>
  );
}
