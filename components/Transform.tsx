"use client";

import { motion } from "framer-motion";
import { Reveal } from "@/components/Reveal";

const RAW =
  "um so basically let them know the quote is ready, its gonna be like 4 grand, no wait, 4500 with the extra coverage part and um we can start tuesday if they sign tonight";

const CLEAN =
  "Your quote is ready: $4,500 including the extra coverage. We can start Tuesday if you sign tonight.";

// Callouts pinned over the messy transcript, naming each fix as it happens.
const NOTES = [
  { label: "Filler removed", top: "8%", left: "3%", delay: 0.2 },
  { label: "Corrected to $4,500", top: "38%", left: "40%", delay: 0.55 },
  { label: "Punctuation added", top: "70%", left: "8%", delay: 0.9 },
];

export function Transform() {
  return (
    <section className="mx-auto max-w-6xl px-5 py-24">
      <Reveal>
        <h2 className="text-center font-display text-4xl leading-tight text-ink sm:text-5xl">
          It cleans up the way people{" "}
          <span className="italic text-rosedeep">actually</span> talk
        </h2>
        <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
          You do not have to speak in tidy sentences. Say it however it comes
          out, including the ums and the false starts and the moment where you
          change your mind halfway through, and NessoTalk sorts all of it out
          before the text reaches the page.
        </p>
      </Reveal>

      <div className="mt-14 grid items-stretch gap-6 lg:grid-cols-2">
        <Reveal>
          <div className="relative h-full overflow-hidden rounded-3xl bg-ink p-8">
            <div className="text-xs font-semibold uppercase tracking-wide text-paper/70">
              What you said
            </div>
            <p className="mt-4 font-mono text-sm leading-8 text-paper/85">{RAW}</p>
            {NOTES.map((n) => (
              <motion.span
                key={n.label}
                initial={{ opacity: 0, scale: 0.85, rotate: -3 }}
                whileInView={{ opacity: 1, scale: 1, rotate: -2 }}
                viewport={{ once: true }}
                transition={{ duration: 0.45, delay: n.delay }}
                style={{ top: n.top, left: n.left }}
                className="absolute rounded-full bg-rose px-3.5 py-1.5 text-xs font-bold text-ink shadow-pill"
              >
                {n.label}
              </motion.span>
            ))}
          </div>
        </Reveal>

        <Reveal delay={1}>
          <div className="flex h-full flex-col justify-center rounded-3xl border border-rose/40 bg-card p-8 shadow-glow">
            <div className="text-xs font-semibold uppercase tracking-wide text-rosedeep">
              What got typed for you
            </div>
            <p className="mt-4 text-xl leading-9 text-ink">{CLEAN}</p>
            <p className="mt-6 text-sm leading-6 text-muted">
              You never touched the keyboard, and the number you corrected
              halfway through is the one that made it into the message.
            </p>
          </div>
        </Reveal>
      </div>

      <Reveal>
        <div className="mx-auto mt-16 grid max-w-3xl gap-4 sm:grid-cols-2">
          <div className="rounded-3xl border border-line bg-card p-8 text-center">
            <div className="text-sm text-muted">Typing</div>
            <div className="mt-1 font-display text-5xl text-muted">45</div>
            <div className="text-sm text-muted">words per minute</div>
          </div>
          <div className="rounded-3xl bg-ink p-8 text-center">
            <div className="text-sm text-paper/70">Talking</div>
            <div className="mt-1 font-display text-5xl text-paper">200+</div>
            <div className="text-sm text-paper/70">words per minute</div>
          </div>
        </div>
        <p className="mt-5 text-center text-base text-muted">
          You already speak at roughly this speed every day, so this is simply
          your writing catching up to your talking.
        </p>
      </Reveal>
    </section>
  );
}
