import Link from "next/link";
import { Check, X } from "lucide-react";

const OURS = [
  "Unlimited dictation on your Mac",
  "Runs on our own speech engine, so nothing heavy sits on your computer",
  "Five modes: Professional, Summarize, Normal, AI Agent, AI Extend",
  "Learns you: your usual mode per app becomes automatic",
  "Edit selected text by voice",
  "Custom dictionary, voice snippets, 100+ languages",
];

export default function Pricing() {
  return (
    <section id="pricing" className="mx-auto max-w-6xl px-5 py-24">
      <h2 className="text-center font-display text-4xl text-ink sm:text-5xl">
        It costs a third of what the other tools charge, and that is deliberate
      </h2>
      <p className="mx-auto mt-4 max-w-2xl text-center text-muted">
        The well-known apps charge about fifteen dollars a month forever.
        NessoTalk runs on our own speech engine instead of renting someone
        else&apos;s by the minute, so the low price is structural, not a launch
        discount. Founding members keep it for as long as they stay subscribed.
      </p>

      <div className="mx-auto mt-14 grid max-w-4xl gap-6 sm:grid-cols-2">
        <div className="rounded-3xl border border-line bg-card/40 p-8">
          <div className="text-sm font-medium text-muted">The other guys</div>
          <div className="mt-2 font-display text-4xl text-muted">
            $15<span className="text-lg">/mo</span>
          </div>
          <ul className="mt-6 space-y-3 text-sm text-muted">
            <li className="flex gap-2"><X className="mt-0.5 h-4 w-4 shrink-0 text-muted" />Priced like a corporate tool, even for personal use</li>
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
    "Your recording goes over an encrypted connection to NessoTalk's own speech engine, is turned into text, and is discarded in the same request. It is never written to disk, never kept, never sold, and never handed to a third-party AI company, because the engine is ours and it runs on our own servers.",
  ],
  [
    "How is this different from Wispr Flow?",
    "Same core magic: talk anywhere, clean text appears. NessoTalk gives you five rewrite modes, including briefs written specifically for AI coding agents, it learns the words you use and which mode you want in each app, and it costs about a third as much. We run our own speech engine on our own servers instead of renting one by the minute, which is how the price stays low.",
  ],
  [
    "What do I need to run it?",
    "Any modern Mac, and an internet connection, because your words are transcribed on our engine rather than on your computer. Setup takes about a minute now that there is no large model to download. You grant microphone permission once, and that is the last setup step. Windows is in progress and is not released yet.",
  ],
  [
    "What happens after the 14-day trial?",
    "Your trial starts the moment you create an account, and no card is needed. When it ends you can subscribe for $4.99 a month. Founding-member pricing is locked for as long as you stay subscribed.",
  ],
  [
    "Can I cancel anytime?",
    "Yes. Email Brady and your subscription is cancelled the same day, with no calls and no retention flow. A self-serve cancel button is being built and is not live yet.",
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
