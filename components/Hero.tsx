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

      {/* Curved speech line, mirrored on both sides of the headline. */}
      <svg
        aria-hidden
        viewBox="0 0 1200 420"
        className="pointer-events-none absolute inset-x-0 top-24 mx-auto hidden h-[420px] w-full max-w-6xl lg:block"
      >
        <defs>
          <path id="arcL" d="M 40 380 Q 150 120 420 90" fill="none" />
          <path id="arcR" d="M 780 90 Q 1050 120 1160 380" fill="none" />
        </defs>
        <text className="fill-ink/25 font-body text-[15px]">
          <textPath href="#arcL" startOffset="0%">
            {CURVE_TEXT}
          </textPath>
        </text>
        <text className="fill-ink/25 font-body text-[15px]">
          <textPath href="#arcR" startOffset="0%">
            {CURVE_TEXT}
          </textPath>
        </text>
      </svg>

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
          className="mt-9 font-display text-5xl leading-[1.03] tracking-tight text-ink sm:text-7xl"
        >
          Say it once and it is<br className="hidden sm:block" />{" "}
          <span className="italic text-rosedeep">already written</span>
        </motion.h1>

        <motion.p
          initial={{ opacity: 0, y: 18 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.7, delay: 0.2 }}
          className="mx-auto mt-7 max-w-2xl text-lg leading-8 text-muted"
        >
          You tap one key and start talking, and a few seconds later your words
          are sitting in whatever you were writing, punctuated and cleaned up.
          It works in every program on your computer, and the listening happens
          on your own machine rather than on somebody else's server.
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
        transition={{ duration: 0.8, delay: 0.4 }}
        className="relative mx-auto mt-16 max-w-2xl"
      >
        <WaveformPill />
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
