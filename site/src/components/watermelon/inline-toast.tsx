'use client';

// Watermelon UI's inline toast (MIT), adapted for ClickBait: dark only, fits a phone,
// monospace command text, and the result is announced to screen readers.

import { useState, type FC } from 'react';
import { motion, AnimatePresence } from 'motion/react';
import { IoCheckmarkCircle } from 'react-icons/io5';

export interface InlineCopyToastProps {
  code: string;
  copyDuration?: number;
}

export const InlineToast: FC<InlineCopyToastProps> = ({
  code,
  copyDuration = 2000,
}) => {
  const [copied, setCopied] = useState<boolean>(false);

  const handleCopy = async (): Promise<void> => {
    await navigator.clipboard.writeText(code);
    setCopied(true);

    setTimeout(() => {
      setCopied(false);
    }, copyDuration);
  };

  return (
    <motion.div
      layout="position"
      transition={{ type: 'spring', stiffness: 260, damping: 24 }}
      className="relative flex h-14 w-full min-w-0 max-w-md items-center justify-center overflow-hidden rounded-full border border-white/10 bg-zinc-900 pl-4 pr-1.5 shadow-sm sm:pl-5"
    >
      <AnimatePresence>
        {copied && (
          <motion.div
            initial={{ x: '-100%' }}
            animate={{ x: '0%' }}
            transition={{
              duration: copyDuration / 1000,
              ease: 'linear',
            }}
            className="absolute inset-0 bg-zinc-800"
          />
        )}
      </AnimatePresence>

      <div className="z-10 flex w-full min-w-0 items-center justify-between gap-3">
        <AnimatePresence mode="popLayout">
          {!copied ? (
            <motion.div
              key="copy"
              initial={{ opacity: 0, filter: 'blur(4px)', scale: 0.95 }}
              animate={{ opacity: 1, filter: 'blur(0px)', scale: 1 }}
              exit={{ opacity: 0, filter: 'blur(4px)', scale: 0.95 }}
              transition={{
                type: 'spring',
                bounce: 0,
                duration: 0.4,
              }}
              className="flex w-full min-w-0 items-center justify-between gap-3"
            >
              <code className="min-w-0 truncate font-mono text-[13px] font-semibold text-zinc-200">
                {code}
              </code>

              <motion.button
                onClick={handleCopy}
                type="button"
                aria-label={`Copy ${code}`}
                whileHover={{ y: -1, scale: 1.04 }}
                whileTap={{ scale: 0.96 }}
                transition={{
                  type: 'spring',
                  stiffness: 350,
                  damping: 18,
                }}
                className="relative shrink-0 cursor-pointer overflow-hidden rounded-full bg-zinc-100 px-4 py-2 text-sm font-semibold text-black shadow-[0_6px_12px_rgba(0,0,0,0.08)]"
              >
                <motion.span
                  initial={{ x: '-120%' }}
                  whileHover={{ x: '120%' }}
                  transition={{ duration: 0.6, ease: 'easeInOut' }}
                  className="pointer-events-none absolute inset-0 bg-linear-to-r from-transparent via-black/5 to-transparent"
                />

                <span className="relative z-10">Copy</span>
              </motion.button>
            </motion.div>
          ) : (
            <motion.div
              key="copied"
              initial={{ opacity: 0, filter: 'blur(4px)', scale: 1.1 }}
              animate={{ opacity: 1, filter: 'blur(0px)', scale: 1 }}
              exit={{ opacity: 0, filter: 'blur(4px)', scale: 1.1 }}
              transition={{
                type: 'spring',
                bounce: 0,
                duration: 0.4,
              }}
              className="flex w-full items-center justify-center gap-2 text-white"
            >
              <IoCheckmarkCircle size={24} aria-hidden="true" />
              <span className="text-base font-bold">Copied!</span>
            </motion.div>
          )}
        </AnimatePresence>
      </div>
      <span className="sr-only" aria-live="polite">{copied ? 'Copied to the clipboard' : ''}</span>
    </motion.div>
  );
};
