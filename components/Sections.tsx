import Link from "next/link";
import {
  Lock,
  MessageSquareText,
  BookOpenCheck,
  Globe2,
  MousePointerClick,
  Mic,
} from "lucide-react";

export function ProofBar() {
  return (
    <div className="border-y border-line bg-card/50">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-6 px-5 py-8 text-center sm:grid-cols-4">
        {[
          ["~2s", "from stop tap to pasted text"],
          ["100%", "of transcription runs on your Mac"],
          ["3x", "cheaper than the big-name tool"],
          ["45 min", "max dictation, pastes in seconds"],
        ].map(([n, l]) => (
          <div key={l}>
            <div className="font-display text-3xl text-ink">{n}</div>
            <div className="mt-1 text-xs text-muted">{l}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

const APPS_A = [
  "Gmail",
  "Slack",
  "iMessage",
  "Notion",
  "Google Docs",
  "Outlook",
  "Word",
  "Safari",
  "Discord",
  "WhatsApp",
  "Teams",
  "Figma",
];

const APPS_B = [
  "ChatGPT",
  "Claude",
  "Cursor",
  "VS Code",
  "Terminal",
  "Excel",
  "Linear",
  "Telegram",
  "Pages",
  "Chrome",
  "LinkedIn",
  "Notes",
];

export function AppsMarquee() {
  return (
    <section className="border-y border-line bg-card/50 py-20">
      <h2 className="px-5 text-center font-display text-4xl text-ink sm:text-5xl">
        It types into every app you already use
      </h2>
      <p className="mx-auto mt-4 max-w-xl px-5 text-center text-muted">
        As far as your computer is concerned, NessoTalk is a very fast
        keyboard, so it works anywhere your cursor does.
      </p>
      <div className="mt-12 space-y-4 overflow-hidden">
        {[APPS_A, APPS_B].map((row, r) => (
          <div
            key={r}
            className="marquee-track"
            style={
              r === 1
                ? { animationDirection: "reverse", animationDuration: "46s" }
                : { animationDuration: "42s" }
            }
          >
            {[0, 1].map((copy) => (
              <span key={copy} className="flex gap-3 pr-3">
                {row.map((app) => (
                  <span
                    key={app}
                    className="whitespace-nowrap rounded-full border border-line bg-paper px-5 py-2.5 text-sm font-semibold text-ink"
                  >
                    {app}
                  </span>
                ))}
              </span>
            ))}
          </div>
        ))}
      </div>
    </section>
  );
}

export function FeatureGrid() {
  const feats = [
    {
      icon: Lock,
      title: "Private by architecture",
      body: "Speech never leaves your Mac. The transcription engine runs locally, so your words are not someone else's training data.",
    },
    {
      icon: MessageSquareText,
      title: "Knows where you're typing",
      body: "Dictating into Messages or Mail comes out polished and professional. Dictating into an AI tool comes out as a structured prompt.",
    },
    {
      icon: MousePointerClick,
      title: "Edit anything by voice",
      body: "Highlight text anywhere, hold Option, tap the key, and say the change. The rewrite replaces the selection.",
    },
    {
      icon: BookOpenCheck,
      title: "Learns your words",
      body: "Teach it names, products, and jargon once. It spells them right forever, plus voice snippets for things you say daily.",
    },
    {
      icon: Globe2,
      title: "100+ languages",
      body: "Flip one setting and it auto-detects language, even when you switch mid-sentence.",
    },
    {
      icon: Mic,
      title: "Whisper mode",
      body: "In a coffee shop or on a call, dictate at a whisper and it still hears every word.",
    },
  ];
  return (
    <section className="border-y border-line bg-card/40 py-24">
      <div className="mx-auto max-w-6xl px-5">
        <h2 className="text-center font-display text-4xl text-ink">
          Everything the expensive tools do, plus a few things they don't
        </h2>
        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {feats.map((f) => (
            <div key={f.title} className="rounded-2xl border border-line bg-paper/60 p-6">
              <f.icon className="h-5 w-5 text-rose" />
              <h3 className="mt-3 font-semibold text-ink">{f.title}</h3>
              <p className="mt-2 text-sm leading-6 text-muted">{f.body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export function FinalCTA() {
  return (
    <section className="mx-auto max-w-4xl px-5 py-28 text-center">
      <h2 className="font-display text-4xl text-ink sm:text-5xl">
        Your keyboard has done enough work for one career
      </h2>
      <p className="mx-auto mt-4 max-w-xl text-muted">
        You get fourteen days free, and most people are talking to their
        computer within a minute of finishing setup.
      </p>
      <Link
        href="/start"
        className="mt-8 inline-block rounded-xl bg-rose px-10 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-rosedeep"
      >
        Start your free trial
      </Link>
    </section>
  );
}

export function Footer() {
  return (
    <footer className="border-t border-line py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-5 text-sm text-muted sm:flex-row">
        <span>NessoTalk is built for people who think and talk faster than they can type.</span>
        <div className="flex gap-6">
          <a href="/#pricing" className="hover:text-ink">Pricing</a>
          <a href="/#faq" className="hover:text-ink">FAQ</a>
          <a href="mailto:bschwartz1725@gmail.com" className="hover:text-ink">Contact</a>
        </div>
      </div>
    </footer>
  );
}
