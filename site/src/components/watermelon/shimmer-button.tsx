import { cn } from "@/lib/utils";

// Watermelon UI's shimmer button (MIT), plus a link version: a download is a link, and a
// button inside a link isn't valid HTML.

interface ShimmerButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  children: React.ReactNode;
}

const base = cn(
  "relative overflow-hidden px-6 py-3 rounded-lg font-medium",
  "bg-primary text-primary-foreground",
  "hover:shadow-lg transition-shadow duration-300",
  "group",
);

function Shine({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={cn(
        "absolute inset-0 -translate-x-full",
        "bg-linear-to-r from-transparent via-white/20 to-transparent",
        "group-hover:translate-x-full group-focus-visible:translate-x-full transition-transform duration-700",
        className,
      )}
    />
  );
}

export function ShimmerButton({ children, className, ...props }: ShimmerButtonProps) {
  return (
    <button className={cn(base, className)} {...props}>
      <span className="relative z-10">{children}</span>
      <Shine />
    </button>
  );
}

interface ShimmerLinkProps extends React.AnchorHTMLAttributes<HTMLAnchorElement> {
  children: React.ReactNode;
  /** The sweep's colour, e.g. "via-black/10" on a white button. */
  shineClassName?: string;
}

export function ShimmerLink({ children, className, shineClassName, ...props }: ShimmerLinkProps) {
  return (
    <a className={cn(base, className)} {...props}>
      <span className="relative z-10 flex items-center gap-2">{children}</span>
      <Shine className={shineClassName} />
    </a>
  );
}
