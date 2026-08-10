"use client";

import { useState } from "react";
import { Check, Download, ShieldCheck, Mic, Sparkles } from "lucide-react";

// Guided setup, one step at a time. Nobody reads a wall of instructions, so
// each step shows exactly one thing to do and nothing else.
const STEPS = [
  {
    icon: Download,
    title: "Download your copy",
    time: "20 seconds",
    body: "Your license is already inside this file, so there is no key to type and nothing to activate. Pick your computer and the download starts.",
    hint: "Already installed the version from the home page? Copy your key above and paste it into Settings instead.",
    action: "download",
  },
  {
    icon: ShieldCheck,
    title: "Run the installer",
    time: "1 minute",
    body: "Unzip the file, then double-click install.sh on Mac or setup.ps1 on Windows. It sets everything up and tells you when it's done.",
    hint: "On Mac you may need to right-click and choose Open the first time.",
  },
  {
    icon: Mic,
    title: "Say yes to the microphone",
    time: "15 seconds",
    body: "Your computer asks for microphone and accessibility permission once. NessoTalk needs both: one to hear you, one to type for you.",
    hint: "Nothing is recorded until you press the key, and recordings are discarded the moment they become text.",
  },
  {
    icon: Sparkles,
    title: "Tap Right Command and talk",
    time: "10 seconds",
    body: "Click into any text box, tap the Right Command key, and say a sentence. Tap again and your words appear, cleaned up. Press Escape any time to throw a recording away.",
    hint: "That's it. You're done setting up.",
  },
];

export default function Walkthrough({ paid }: { paid: boolean }) {
  const [step, setStep] = useState(0);
  const [done, setDone] = useState<number[]>([]);
  const s = STEPS[step];
  const Icon = s.icon;

  function next() {
    setDone((d) => (d.includes(step) ? d : [...d, step]));
    if (step < STEPS.length - 1) setStep(step + 1);
  }

  return (
    <div className="rounded-3xl border border-line bg-card p-8">
      <div className="flex items-center justify-between">
        <h2 className="font-display text-2xl text-ink">Set up NessoTalk</h2>
        <span className="text-xs text-muted">about 2 minutes total</span>
      </div>

      <div className="mt-5 flex gap-2">
        {STEPS.map((_, i) => (
          <button
            key={i}
            onClick={() => setStep(i)}
            className={`h-1.5 flex-1 rounded-full transition ${
              done.includes(i) ? "bg-rose" : i === step ? "bg-rose/50" : "bg-ink/10"
            }`}
            aria-label={`Step ${i + 1}`}
          />
        ))}
      </div>

      <div className="mt-7 flex gap-4">
        <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-rose/15">
          <Icon className="h-5 w-5 text-rosedeep" />
        </div>
        <div className="min-w-0">
          <div className="flex items-baseline gap-3">
            <h3 className="font-display text-xl text-ink">
              {step + 1}. {s.title}
            </h3>
            <span className="text-xs text-muted">{s.time}</span>
          </div>
          <p className="mt-2 text-sm leading-6 text-muted">{s.body}</p>
          {s.hint && <p className="mt-2 text-xs leading-5 text-muted">{s.hint}</p>}

          {s.action === "download" && (
            <div className="mt-5 grid grid-cols-2 gap-3">
              <a
                href={paid ? "/api/download?platform=mac" : undefined}
                onClick={paid ? next : undefined}
                aria-disabled={!paid}
                className={`rounded-xl py-3 text-center text-sm font-semibold transition ${
                  paid
                    ? "bg-ink text-paper hover:bg-rosedeep"
                    : "pointer-events-none bg-ink/10 text-muted"
                }`}
              >
                 Mac
              </a>
              <a
                href={paid ? "/api/download?platform=windows" : undefined}
                onClick={paid ? next : undefined}
                aria-disabled={!paid}
                className={`rounded-xl py-3 text-center text-sm font-semibold transition ${
                  paid
                    ? "bg-ink text-paper hover:bg-rosedeep"
                    : "pointer-events-none bg-ink/10 text-muted"
                }`}
              >
                ⊞ Windows
              </a>
            </div>
          )}

          <div className="mt-6 flex items-center gap-3">
            {step > 0 && (
              <button
                onClick={() => setStep(step - 1)}
                className="text-sm text-muted hover:text-ink"
              >
                Back
              </button>
            )}
            {step < STEPS.length - 1 ? (
              <button
                onClick={next}
                className="rounded-lg bg-rose px-5 py-2 text-sm font-semibold text-white transition hover:bg-rosedeep"
              >
                {s.action === "download" ? "I've downloaded it" : "Next"}
              </button>
            ) : (
              <button
                onClick={next}
                className="flex items-center gap-2 rounded-lg bg-rose px-5 py-2 text-sm font-semibold text-white transition hover:bg-rosedeep"
              >
                <Check className="h-4 w-4" /> All set
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
