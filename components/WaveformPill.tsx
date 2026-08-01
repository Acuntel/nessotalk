"use client";

import { useEffect, useState } from "react";

const SCRIPT =
  "okay tell the team the launch moved to thursday, we ship the mac build first, then the site, and the pricing page needs the annual toggle before anything goes live".split(
    " "
  );

const BARS = Array.from({ length: 26 }, (_, i) => ({
  delay: (i * 137) % 900,
  dur: 1200 + ((i * 271) % 900),
}));

export default function WaveformPill() {
  const [count, setCount] = useState(0);
  const [secs, setSecs] = useState(0);

  useEffect(() => {
    const words = setInterval(
      () => setCount((c) => (c >= SCRIPT.length ? 0 : c + 1)),
      240
    );
    const clock = setInterval(() => setSecs((s) => (s + 1) % 60), 1000);
    return () => {
      clearInterval(words);
      clearInterval(clock);
    };
  }, []);

  const shown = SCRIPT.slice(Math.max(0, count - 16), count).join(" ");

  return (
    <div className="floaty mx-auto w-full max-w-2xl rounded-3xl border border-edge bg-panel/90 p-5 shadow-pill backdrop-blur">
      <div className="flex items-center justify-between">
        <span className="font-mono text-sm text-mist">
          0:{String(secs).padStart(2, "0")}
        </span>
        <div className="flex h-8 items-center gap-[3px]">
          {BARS.map((b, i) => (
            <span
              key={i}
              className="wavebar h-full w-[3px] rounded-full bg-cream/90"
              style={{ animationDelay: `${b.delay}ms`, animationDuration: `${b.dur}ms` }}
            />
          ))}
        </div>
        <span className="text-xs text-mist">Right ⌘ to stop</span>
      </div>

      <p className="mt-4 min-h-[3.5rem] text-left text-lg font-medium leading-7 text-cream">
        {shown}
        <span className="ml-1 inline-block h-4 w-[2px] animate-pulse bg-volt align-middle" />
      </p>

      <div className="mt-4 flex justify-center gap-2">
        <span className="rounded-full bg-white/10 px-4 py-1.5 text-xs font-medium text-mist">
          Summarize
        </span>
        <span className="rounded-full bg-white/10 px-4 py-1.5 text-xs font-medium text-mist">
          Normal
        </span>
        <span className="rounded-full bg-volt/30 px-4 py-1.5 text-xs font-bold text-cream ring-1 ring-volt/60">
          Professional
        </span>
      </div>
    </div>
  );
}
