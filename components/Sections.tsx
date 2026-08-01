import Link from "next/link";
import {
  Lock,
  Zap,
  Wand2,
  MessageSquareText,
  BookOpenCheck,
  Globe2,
  MousePointerClick,
  Mic,
} from "lucide-react";

export function ProofBar() {
  return (
    <div className="border-y border-edge bg-panel/50">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-6 px-5 py-8 text-center sm:grid-cols-4">
        {[
          ["~2s", "from stop tap to pasted text"],
          ["100%", "of transcription runs on your Mac"],
          ["3x", "cheaper than the big-name tool"],
          ["45 min", "max dictation, pastes in seconds"],
        ].map(([n, l]) => (
          <div key={l}>
            <div className="font-display text-3xl text-cream">{n}</div>
            <div className="mt-1 text-xs text-mist">{l}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

export function HowItWorks() {
  const steps = [
    {
      icon: Mic,
      title: "Tap a key, talk",
      body: "One tap on Right Command starts listening in any app. A live transcript rolls on screen while you speak.",
    },
    {
      icon: Wand2,
      title: "Pick how it lands",
      body: "Exact words, a structured AI prompt, or clean professional prose for texts and email. One click on the pill, or let it choose by app.",
    },
    {
      icon: Zap,
      title: "It pastes. You move on.",
      body: "Tap again and polished text lands right where your cursor is, usually in about two seconds.",
    },
  ];
  return (
    <section id="how" className="mx-auto max-w-6xl px-5 py-24">
      <h2 className="text-center font-display text-4xl text-cream sm:text-5xl">
        Typing was the bottleneck
      </h2>
      <p className="mx-auto mt-4 max-w-2xl text-center text-mist">
        You think at 150 words a minute and type at 45. NessoTalk closes the gap
        in every single Mac app: email, Slack, docs, your AI tools, all of it.
      </p>
      <div className="mt-14 grid gap-8 sm:grid-cols-3">
        {steps.map((s) => (
          <div key={s.title} className="rounded-2xl border border-edge bg-panel/60 p-7">
            <s.icon className="h-6 w-6 text-volt" />
            <h3 className="mt-4 font-display text-xl text-cream">{s.title}</h3>
            <p className="mt-2 text-sm leading-6 text-mist">{s.body}</p>
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
    <section className="border-y border-edge bg-panel/40 py-24">
      <div className="mx-auto max-w-6xl px-5">
        <h2 className="text-center font-display text-4xl text-cream">
          Everything the expensive tools do. And a few things they don't.
        </h2>
        <div className="mt-14 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
          {feats.map((f) => (
            <div key={f.title} className="rounded-2xl border border-edge bg-ink/60 p-6">
              <f.icon className="h-5 w-5 text-volt" />
              <h3 className="mt-3 font-semibold text-cream">{f.title}</h3>
              <p className="mt-2 text-sm leading-6 text-mist">{f.body}</p>
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
      <h2 className="font-display text-4xl text-cream sm:text-5xl">
        Your keyboard had a good run.
      </h2>
      <p className="mx-auto mt-4 max-w-xl text-mist">
        14 days free. No card. You'll be dictating within a minute of signing up.
      </p>
      <Link
        href="/start"
        className="mt-8 inline-block rounded-xl bg-volt px-10 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-voltdim"
      >
        Start your free trial
      </Link>
    </section>
  );
}

export function Footer() {
  return (
    <footer className="border-t border-edge py-10">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-5 text-sm text-mist sm:flex-row">
        <span>NessoTalk. Made for people who talk faster than they type.</span>
        <div className="flex gap-6">
          <a href="/#pricing" className="hover:text-cream">Pricing</a>
          <a href="/#faq" className="hover:text-cream">FAQ</a>
          <a href="mailto:bschwartz1725@gmail.com" className="hover:text-cream">Contact</a>
        </div>
      </div>
    </footer>
  );
}
