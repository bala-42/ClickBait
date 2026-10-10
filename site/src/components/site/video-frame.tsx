import { TONES, type Tone } from "@/lib/site";
import { MacWindow } from "./window";
import { Triangle } from "./triangle";

/**
 * A demo video in a window frame. Until a recording exists (`src` unset) it shows a
 * labelled placeholder with the shot to record, so the page never looks broken.
 */
export function VideoFrame({
  title,
  tone,
  shot,
  src,
  captions,
  className,
}: {
  title: string;
  tone: Tone;
  /** What the recording should show (also the placeholder's text and the video's label). */
  shot: string;
  src?: string;
  /** A WebVTT captions file for the recording. */
  captions?: string;
  className?: string;
}) {
  const colour = TONES[tone].hex;
  return (
    <figure className={className}>
      <MacWindow title={title} bodyClassName="aspect-[16/10]">
        {src ? (
          <video
            className="size-full object-cover"
            src={src}
            aria-label={shot}
            autoPlay
            muted
            loop
            playsInline
            controls
            preload="metadata"
          >
            {captions && <track kind="captions" src={captions} srcLang="en" label="English" default />}
          </video>
        ) : (
          <div
            className="flex size-full flex-col items-center justify-center gap-4 p-6 text-center"
            style={{
              background: `radial-gradient(70% 70% at 50% 40%, ${colour}26, transparent 70%), repeating-linear-gradient(135deg, rgb(255 255 255 / 0.025) 0 12px, transparent 12px 24px)`,
            }}
          >
            <Triangle tone={tone} size={34} pulsing />
            <p className="max-w-sm text-sm text-muted-foreground">
              <span className="mb-1 block font-mono text-[11px] uppercase tracking-[0.18em]" style={{ color: TONES[tone].text }}>
                Demo video coming soon
              </span>
              {shot}
            </p>
          </div>
        )}
      </MacWindow>
      <figcaption className="sr-only">{shot}</figcaption>
    </figure>
  );
}
