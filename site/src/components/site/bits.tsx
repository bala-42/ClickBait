import { TONES, type Tone } from "@/lib/site";
import { cn } from "@/lib/utils";

/**
 * A section heading that starts as clickbait, gets crossed out, and tells the truth.
 * The crossed-out line is decoration; screen readers get the honest heading.
 */
export function BaitHeading({
  id,
  bait,
  children,
  tone,
  kicker,
  className,
}: {
  id?: string;
  bait: string;
  children: React.ReactNode;
  tone: Tone;
  kicker: string;
  className?: string;
}) {
  return (
    <div className={cn("max-w-3xl", className)}>
      <p className="mb-5 flex items-center gap-2 font-mono text-xs uppercase tracking-[0.2em]" style={{ color: TONES[tone].text }}>
        <span className="size-1.5 rounded-full" style={{ background: TONES[tone].hex }} aria-hidden="true" />
        {kicker}
      </p>
      <p aria-hidden="true" className="mb-2 text-base text-muted-foreground/80 line-through decoration-2 sm:text-lg" style={{ textDecorationColor: TONES[tone].hex }}>
        {bait}
      </p>
      <h2 id={id} className="text-balance text-3xl font-semibold tracking-tight sm:text-5xl">
        {children}
      </h2>
    </div>
  );
}

/** Italic serif for the odd word, for warmth. */
export function Em({ children, className }: { children: React.ReactNode; className?: string }) {
  return <em className={cn("font-serif font-normal italic tracking-normal", className)}>{children}</em>;
}

/** A tilted sticker, like the ones on a laptop lid. */
export function Sticker({
  children,
  tone,
  rotate = -6,
  className,
}: {
  children: React.ReactNode;
  tone: Tone;
  rotate?: number;
  className?: string;
}) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        "pointer-events-none inline-flex select-none items-center gap-1.5 whitespace-nowrap rounded-full border-2 border-white/90 px-3.5 py-1.5 font-mono text-[11px] font-bold uppercase tracking-wider text-white shadow-[0_8px_24px_-6px_rgb(0_0_0/0.6)]",
        className,
      )}
      style={{ background: TONES[tone].hex, transform: `rotate(${rotate}deg)` }}
    >
      {children}
    </span>
  );
}

/** A pill like the ones beside the companion. */
export function Pill({ tone, children, className }: { tone: Tone; children: React.ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center whitespace-nowrap rounded-full px-3 py-1.5 text-[13px] font-semibold text-white shadow-lg",
        className,
      )}
      style={{ background: TONES[tone].hex, boxShadow: `0 0 18px ${TONES[tone].hex}66` }}
    >
      {children}
    </span>
  );
}

export function Keys({ keys, className }: { keys: string[]; className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-1.5", className)}>
      {keys.map((key) => (
        <kbd key={key} className="keycap">
          {key}
        </kbd>
      ))}
    </span>
  );
}

export function Section({
  id,
  tone,
  labelledBy,
  className,
  children,
}: {
  id: string;
  tone: Tone;
  labelledBy: string;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <section id={id} data-tone={tone} aria-labelledby={labelledBy} className={cn("relative px-4 py-24 sm:px-6 sm:py-32", className)}>
      <div className="mx-auto max-w-6xl">{children}</div>
    </section>
  );
}
