import Link from "next/link";
import { Check, X } from "lucide-react";

const OURS = [
  "Unlimited dictation on Mac and Windows",
  "Local transcription: audio never uploaded",
  "Summarize, Professional, and exact-words modes",
  "Edit any selected text by voice",
  "Custom dictionary + voice snippets",
  "100+ languages and whisper mode",
];

export default function Pricing() {
  return (
    <section id="pricing" className="mx-auto max-w-6xl px-5 py-24">
      <h2 className="text-center font-display text-4xl text-ink sm:text-5xl">
        It costs a third of what the other tools charge, and that is deliberate
      </h2>
      <p className="mx-auto mt-4 max-w-2xl text-center text-muted">
        The well-known apps charge about fifteen dollars a month forever.
        NessoTalk does the same job on the computer you already own, so it
        costs a third of that.
      </p>

      <div className="mx-auto mt-14 grid max-w-4xl gap-6 sm:grid-cols-2">
        <div className="rounded-3xl border border-line bg-card/40 p-8">
          <div className="text-sm font-medium text-muted">The other guys</div>
          <div className="mt-2 font-display text-4xl text-muted">
            $15<span className="text-lg">/mo</span>
          </div>
          <ul className="mt-6 space-y-3 text-sm text-muted">
            <li className="flex gap-2"><X className="mt-0.5 h-4 w-4 shrink-0 text-muted" />Audio processed in their cloud</li>
            <li className="flex gap-2"><X className="mt-0.5 h-4 w-4 shrink-0 text-muted" />$180 a year, every year</li>
            <li className="flex gap-2"><Check className="mt-0.5 h-4 w-4 shrink-0 text-muted" />It is genuinely good dictation, to be fair to them</li>
          </ul>
        </div>

        <div className="relative rounded-3xl border border-rose/50 bg-card p-8 shadow-glow">
          <span className="absolute -top-3 left-8 rounded-full bg-rose px-3 py-1 text-xs font-bold text-white">
            Founding price, locked forever
          </span>
          <div className="text-sm font-medium text-ink">NessoTalk</div>
          <div className="mt-2 font-display text-5xl text-ink">
            $4.99<span className="text-lg text-muted">/mo</span>
          </div>
          <div className="mt-1 text-sm text-muted">or $39/year (35% off)</div>
          <ul className="mt-6 space-y-3 text-sm text-ink">
            {OURS.map((f) => (
              <li key={f} className="flex gap-2">
                <Check className="mt-0.5 h-4 w-4 shrink-0 text-rose" />
                {f}
              </li>
            ))}
          </ul>
          <Link
            href="/start"
            className="mt-8 block rounded-xl bg-rose py-3.5 text-center font-semibold text-white transition hover:bg-rosedeep"
          >
            Start 14 days free
          </Link>
          <p className="mt-3 text-center text-xs text-muted">No card required</p>
        </div>
      </div>
    </section>
  );
}

const QA = [
  [
    "Is my audio really private?",
    "Yes. Speech-to-text runs entirely on your Mac. The only time text touches the cloud is when you explicitly pick an AI rewrite mode (Summarize or Professional), and that sends text, never audio. Exact-words mode is 100% offline.",
  ],
  [
    "How is this different from Wispr Flow?",
    "Same core magic: talk anywhere, clean text appears. The differences: transcription is local instead of cloud, you get voice editing of selected text, and it costs about a third as much.",
  ],
  [
    "What do I need to run it?",
    "On Mac: Apple Silicon (M1 or newer) runs it best. On Windows: Windows 11 with the .NET 9 runtime, which the installer sets up for you. Either way you grant microphone permission once during a guided setup.",
  ],
  [
    "What happens after the 14-day trial?",
    "Your trial starts the moment you create an account, no card needed. When it ends you can subscribe for $4.99/mo or $39/yr. Founding-member pricing is locked for as long as you stay subscribed.",
  ],
  [
    "Can I cancel anytime?",
    "Yes, one click from your dashboard. No calls, no retention flows, no guilt trips.",
  ],
];

export function FAQ() {
  return (
    <section id="faq" className="border-t border-line bg-card/40 py-24">
      <div className="mx-auto max-w-3xl px-5">
        <h2 className="text-center font-display text-4xl text-ink">
          The questions people ask before they sign up
        </h2>
        <div className="mt-10 space-y-4">
          {QA.map(([q, a]) => (
            <details key={q} className="group rounded-2xl border border-line bg-paper/60 p-6">
              <summary className="cursor-pointer list-none font-semibold text-ink marker:content-none">
                {q}
              </summary>
              <p className="mt-3 text-sm leading-6 text-muted">{a}</p>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
