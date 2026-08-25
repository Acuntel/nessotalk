"use client";

import { useState } from "react";
import { Check, Download, ShieldCheck, Mic, Sparkles } from "lucide-react";

// Guided setup, one step at a time. Nobody reads a wall of instructions, so
// each step shows exactly one thing to do and nothing else.
const STEPS = [
  {
    icon: Download,
    title: "Install NessoTalk",
    time: "20 seconds",
    // Reframed away from "download your copy". Your words are transcribed on the
    // NessoTalk engine, so what lands on the customer's Mac is a small app that
    // reaches it, not a speech model. Saying "download" made the app sound like
    // the product; the subscription is the product.
    body: "The app is small, because the work happens on our engine rather than on your computer. Your license is already inside the file, so there is nothing to type and nothing to activate.",
    hint: "Setting up a second computer, or installed from the home page already? Copy your key above and paste it into Settings instead.",
    action: "download",
  },
  {
    icon: ShieldCheck,
    title: "Run the installer",
    time: "1 minute",
    body: "Unzip the file, then double-click Install NessoTalk. It sets everything up and tells you when it is done.",
    hint: "macOS will say it cannot verify the app, because NessoTalk is not yet notarized by Apple. Open System Settings, go to Privacy and Security, scroll to the bottom, and click Open Anyway. Right-clicking and choosing Open no longer works on macOS 15 and later.",
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

export default function Walkthrough() {
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
                href="/api/download?platform=mac"
                onClick={next}
                className="rounded-xl bg-ink py-3 text-center text-sm font-semibold text-paper transition hover:bg-rosedeep"
              >
                 Install for Mac
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
                className="rounded-lg bg-rosedark px-5 py-2 text-sm font-semibold text-white transition hover:bg-rosepress"
              >
                {s.action === "download" ? "I've downloaded it" : "Next"}
              </button>
            ) : (
              <button
                onClick={next}
                className="flex items-center gap-2 rounded-lg bg-rosedark px-5 py-2 text-sm font-semibold text-white transition hover:bg-rosepress"
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
