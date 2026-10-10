"use client";

import { motion, useReducedMotion } from "motion/react";
import { TONES, type Tone } from "@/lib/site";
import { cn } from "@/lib/utils";

// An equilateral triangle whose tip (2, 2) points up-left, like the app's companion.
// The other corners sit at ±30° either side of the down-right axis.
const PATH = "M2 2 L21.3 7.2 L7.2 21.3 Z";
// Its centre, so a spin turns it in place.
const CENTRE = "42.4% 42.4%";

type Props = {
  tone: Tone;
  size?: number;
  /** Thinking: turns a third at a time, springing a little past each stop and settling. */
  spinning?: boolean;
  /** Pulse the glow (working, pointing). */
  pulsing?: boolean;
  /** Degrees to turn the tip toward something (0 = up-left). */
  rotate?: number;
  className?: string;
};

export function Triangle({ tone, size = 22, spinning = false, pulsing = false, rotate = 0, className }: Props) {
  const reduce = useReducedMotion();
  const colour = TONES[tone].hex;
  const thirds = { rotate: [rotate, rotate + 120 + 20, rotate + 120, rotate + 120] };

  return (
    <motion.svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      aria-hidden="true"
      className={cn("overflow-visible", className)}
      style={{ transformOrigin: CENTRE }}
      initial={false}
      animate={
        spinning && !reduce
          ? thirds
          : { rotate, filter: `drop-shadow(0 0 ${pulsing ? 10 : 6}px ${colour}${pulsing ? "cc" : "99"})` }
      }
      transition={
        spinning && !reduce
          ? { duration: 0.9, times: [0, 0.35, 0.55, 1], ease: "easeOut", repeat: Infinity }
          : pulsing && !reduce
            ? { filter: { duration: 1.1, repeat: Infinity, repeatType: "reverse" }, rotate: { type: "spring", stiffness: 200, damping: 22 } }
            : { type: "spring", stiffness: 200, damping: 22 }
      }
    >
      <motion.path
        d={PATH}
        initial={false}
        animate={{ fill: colour, stroke: colour }}
        transition={{ duration: 0.35 }}
        strokeWidth={2.6}
        strokeLinejoin="round"
        style={{ filter: `drop-shadow(0 0 5px ${colour}aa)` }}
      />
    </motion.svg>
  );
}
