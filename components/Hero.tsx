"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import WaveformPill from "@/components/WaveformPill";

const PLATFORMS = [" Mac", "⊞ Windows"];

// The line that curves around the hero, as if the words you spoke are still
// travelling toward the page.
const CURVE_TEXT =
  "can you check in with them and see if the notes from yesterday's meeting were sent over yet";

export default function Hero() {
  const [beat, setBeat] = useState(0);
  useEffect(() => {
    const t = setInterval(() => setBeat((b) => (b + 1) % 3), 2600);
    return () => clearInterval(t);
  }, []);

  return (
    <section className="relative overflow-hidden px-5 pb-20 pt-32 sm:pt-40">
      <div
        aria-hidden
        className="pointer-events-none absolute left-1/2 top-16 h-80 w-[46rem] -translate-x-1/2 rounded-full bg-rose/25 blur-[130px]"
      />

      {/* The spoken line travelling across the page under the demo. */}

      <div className="relative mx-auto max-w-4xl text-center">
        <motion.div
          initial={{ opacity: 0, y: 14 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.6 }}
          className="flex items-center justify-center gap-3"
        >
          {PLATFORMS.map((p) => (
            <span
              key={p}
              className="rounded-full border border-ink/25 bg-card px-5 py-2 text-sm font-semibold text-ink"
            >
              {p}
            </span>
          ))}
        </motion.div>

        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.1 }}
          className="mt-7 font-display text-4xl leading-[1.05] tracking-tight text-ink sm:text-5xl"
        >
          Say it once and it is<br className="hidden sm:block" />{" "}
          <span className="italic text-rosedeep">already written</span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.2 }}
          className="mx-auto mt-5 max-w-xl text-lg leading-8 text-muted"
        >
          Tap one key, say it out loud, and the finished writing appears where
          your cursor already was, in any program on your computer.
        </motion.p>

        <motion.div
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.3 }}
          className="mt-9 flex flex-col items-center gap-4"
        >
          <Link
            href="/start"
            className="rounded-2xl bg-rose px-10 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-rosedeep"
          >
            Start your 14 day trial
          </Link>
          <p className="text-sm text-muted">
            Free for fourteen days, then $4.99 a month. Cancel in one click.
          </p>
        </motion.div>
      </div>

      <motion.div
        initial={{ opacity: 0, y: 30 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.8, delay: 0.35 }}
        className="relative mx-auto mt-10 max-w-2xl"
      >
        <WaveformPill />
        <div className="pointer-events-none mt-8 overflow-hidden">
          <div className="marquee-track text-lg text-muted">
            {[0, 1].map((copy) => (
              <span key={copy} className="pr-10">
                {CURVE_TEXT} &nbsp;·&nbsp; {CURVE_TEXT} &nbsp;·&nbsp;
              </span>
            ))}
          </div>
        </div>
        <motion.span
          key={beat}
          initial={{ opacity: 0, scale: 0.9, y: 6 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          transition={{ duration: 0.4 }}
          className="absolute -right-2 -top-4 rounded-full bg-ink px-4 py-2 text-xs font-semibold text-paper shadow-pill sm:-right-10"
        >
          {["Filler words removed", "Spelling corrected", "Punctuation added"][beat]}
        </motion.span>
      </motion.div>
    </section>
  );
}
