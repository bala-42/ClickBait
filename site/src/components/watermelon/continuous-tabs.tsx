"use client";

import { useRef, type FC, type KeyboardEvent } from "react";
import { motion, LayoutGroup } from "motion/react";

// Watermelon UI's continuous tabs (MIT), adapted for ClickBait: a real tab list (roles,
// arrow keys, roving focus), rendered on the server instead of after mount, and a pill in
// each tab's own colour.

export interface TabItem {
  id: string;
  label: string;
  /** The sliding pill's colour while this tab is active. */
  colour: string;
}

interface ContinuousTabsProps {
  tabs: TabItem[];
  active: string;
  onChange: (id: string) => void;
  /** The tab list's accessible name. */
  label: string;
  /** id prefix tying each tab to its panel (`${idPrefix}-panel-${id}`). */
  idPrefix: string;
}

export const ContinuousTabs: FC<ContinuousTabsProps> = ({ tabs, active, onChange, label, idPrefix }) => {
  const refs = useRef<(HTMLButtonElement | null)[]>([]);

  const onKeyDown = (event: KeyboardEvent<HTMLButtonElement>, index: number) => {
    const last = tabs.length - 1;
    const next =
      event.key === "ArrowRight" ? (index === last ? 0 : index + 1)
      : event.key === "ArrowLeft" ? (index === 0 ? last : index - 1)
      : event.key === "Home" ? 0
      : event.key === "End" ? last
      : null;
    if (next === null) return;
    event.preventDefault();
    onChange(tabs[next].id);
    refs.current[next]?.focus();
  };

  return (
    <LayoutGroup id={idPrefix}>
      <div
        role="tablist"
        aria-label={label}
        className="relative flex max-w-full flex-wrap items-center justify-center gap-0.5 rounded-[22px] border sm:flex-nowrap sm:rounded-full border-zinc-800 bg-linear-to-b from-zinc-900 to-zinc-950 p-1 shadow-[inset_0_-2px_4px_rgba(0,0,0,0.5),inset_0_1px_0_rgba(255,255,255,0.05),0_10px_20px_rgba(0,0,0,0.4)] sm:gap-1 sm:p-1.5"
      >
        {tabs.map((tab, index) => {
          const isActive = active === tab.id;
          return (
            <button
              key={tab.id}
              ref={(el) => {
                refs.current[index] = el;
              }}
              id={`${idPrefix}-tab-${tab.id}`}
              role="tab"
              type="button"
              aria-selected={isActive}
              aria-controls={`${idPrefix}-panel-${tab.id}`}
              tabIndex={isActive ? 0 : -1}
              onClick={() => onChange(tab.id)}
              onKeyDown={(event) => onKeyDown(event, index)}
              className="relative shrink-0 rounded-full px-3.5 py-2 outline-none focus-visible:ring-2 focus-visible:ring-white/80 sm:px-5 sm:py-2.5"
            >
              {isActive && (
                <motion.span
                  layoutId="active-pill"
                  transition={{ type: "spring", stiffness: 380, damping: 30, mass: 0.9 }}
                  className="absolute inset-0 rounded-full"
                  style={{ background: tab.colour, boxShadow: `0 0 24px ${tab.colour}88` }}
                />
              )}
              <span
                className={`relative z-10 text-sm font-semibold transition-colors duration-200 sm:text-[15px] ${
                  isActive ? "text-white" : "text-zinc-400 hover:text-zinc-200"
                }`}
              >
                {tab.label}
              </span>
            </button>
          );
        })}
      </div>
    </LayoutGroup>
  );
};
