"use client";

import { Reveal } from "@/components/Reveal";

const BARS = Array.from({ length: 22 }, (_, i) => ({
  delay: (i * 149) % 800,
  dur: 1100 + ((i * 233) % 800),
}));

// Each step shows the product itself doing the work; the copy stays out of
// the way at one sentence per step.
function KeycapVisual() {
  return (
    <div className="flex h-full min-h-[230px] items-center justify-center rounded-3xl border border-line bg-card p-8">
      <div className="relative">
        <span className="absolute -inset-3 animate-pulse rounded-[1.6rem] border-2 border-rose/50" />
        <div className="relative rounded-2xl border border-ink/15 bg-paper px-10 py-7 text-center shadow-pill">
          <div className="font-display text-5xl text-ink">⌘</div>
          <div className="mt-2 text-xs font-semibold uppercase tracking-wide text-muted">
            Right Command
          </div>
        </div>
      </div>
    </div>
  );
}

function HudVisual() {
  return (
    <div className="flex h-full min-h-[230px] items-center justify-center rounded-3xl border border-line bg-card p-6">
      <div className="w-full max-w-sm rounded-2xl bg-ink p-4 shadow-pill">
        <div className="flex items-center justify-between gap-3">
          <span className="font-mono text-xs text-paper/70">0:12</span>
          <div className="flex h-6 items-center gap-[2px]">
            {BARS.map((b, i) => (
              <span
                key={i}
                className="wavebar h-full w-[2.5px] rounded-full bg-paper/80"
                style={{ animationDelay: `${b.delay}ms`, animationDuration: `${b.dur}ms` }}
              />
            ))}
          </div>
          <div className="flex items-center gap-1.5">
            <span className="rounded-full bg-emerald-500/90 px-2.5 py-1 text-[10px] font-bold text-white">
              ⚡ Finish
            </span>
            <span className="rounded-full bg-red-500/90 px-2.5 py-1 text-[10px] font-bold text-white">
              Stop
            </span>
          </div>
        </div>
        <p className="mt-3 text-sm leading-6 text-paper/90">
          and tell them the updated quote is ready to send over
          <span className="ml-1 inline-block h-3.5 w-[2px] animate-pulse bg-rose align-middle" />
        </p>
        <div className="mt-3 flex justify-center gap-2 border-t border-white/10 pt-3">
          <span className="rounded-full bg-white/10 px-3 py-1 text-[10px] font-medium text-paper/80">
            ⚙ Settings
          </span>
          <span className="rounded-full bg-rose/30 px-3 py-1 text-[10px] font-bold text-paper ring-1 ring-rose/50">
            ◈ Mode: Professional
          </span>
        </div>
      </div>
    </div>
  );
}

function PastedVisual() {
  return (
    <div className="flex h-full min-h-[230px] items-center justify-center rounded-3xl border border-line bg-card p-6">
      <div className="relative w-full max-w-sm overflow-hidden rounded-2xl border border-line bg-paper shadow-pill">
        <div className="flex items-center gap-1.5 border-b border-line bg-card px-4 py-2.5">
          <span className="h-2.5 w-2.5 rounded-full bg-[#FF5F57]" />
          <span className="h-2.5 w-2.5 rounded-full bg-[#FEBC2E]" />
          <span className="h-2.5 w-2.5 rounded-full bg-[#28C840]" />
          <span className="ml-3 text-[11px] font-medium text-muted">New Message</span>
        </div>
        <div className="border-b border-line px-4 py-2.5 text-[11px] text-muted">
          To: jordan@client.com
        </div>
        <p className="px-4 py-4 pb-10 text-sm leading-6 text-ink">
          Hi Jordan, your updated quote is ready: $4,500 including the extra
          coverage. We can start Tuesday if you sign tonight.
        </p>
        <span className="absolute bottom-3 right-3 rounded-full bg-rose px-3 py-1 text-[10px] font-bold text-ink shadow-pill">
          Pasted in 2.1s
        </span>
      </div>
    </div>
  );
}

const STEPS = [
  {
    n: "01",
    title: "You tap one key",
    body: "One tap of Right Command starts it listening in whatever program you are already in.",
    Visual: KeycapVisual,
  },
  {
    n: "02",
    title: "You talk the way you actually talk",
    body: "Your words appear on the bar as you say them, and you can pick how the writing should come out while you are still speaking.",
    Visual: HudVisual,
  },
  {
    n: "03",
    title: "You tap again and the writing is there",
    body: "About two seconds later the finished text lands exactly where your cursor was, cleaned up and ready to send.",
    Visual: PastedVisual,
  },
];

export function ScrollTour() {
  return (
    <section id="how" className="mx-auto max-w-6xl px-5 py-24">
      <Reveal>
        <h2 className="text-center font-display text-4xl leading-tight text-ink sm:text-5xl">
          Here is what one dictation looks like, start to finish
        </h2>
      </Reveal>

      <div className="mt-14 space-y-12">
        {STEPS.map((s, i) => (
          <Reveal key={s.n} delay={i === 0 ? 0 : 1}>
            <div className="grid items-center gap-8 sm:grid-cols-2">
              <div className={i % 2 === 1 ? "sm:order-2" : ""}>
                <div className="font-display text-3xl text-rose">{s.n}</div>
                <h3 className="mt-2 font-display text-2xl leading-snug text-ink sm:text-3xl">
                  {s.title}
                </h3>
                <p className="mt-3 text-base leading-7 text-muted">{s.body}</p>
              </div>
              <div className={i % 2 === 1 ? "sm:order-1" : ""}>
                <s.Visual />
              </div>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
