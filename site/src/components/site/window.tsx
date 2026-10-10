import { cn } from "@/lib/utils";

/** A macOS-style window: traffic lights, a title, and whatever goes inside. */
export function MacWindow({
  title,
  children,
  className,
  bodyClassName,
}: {
  title: string;
  children: React.ReactNode;
  className?: string;
  bodyClassName?: string;
}) {
  return (
    <div
      className={cn(
        "overflow-hidden rounded-2xl border border-white/10 bg-[#16161d] shadow-[0_40px_120px_-30px_rgb(0_0_0/0.9),0_0_0_1px_rgb(0_0_0/0.4)]",
        className,
      )}
    >
      <div className="flex h-9 items-center gap-2 border-b border-white/[0.07] bg-[#1d1d26] px-3.5">
        <span className="size-3 rounded-full bg-[#ff5f57]" aria-hidden="true" />
        <span className="size-3 rounded-full bg-[#febc2e]" aria-hidden="true" />
        <span className="size-3 rounded-full bg-[#28c840]" aria-hidden="true" />
        <span className="ml-2 truncate text-xs font-medium text-muted-foreground">{title}</span>
      </div>
      <div className={cn("relative", bodyClassName)}>{children}</div>
    </div>
  );
}
