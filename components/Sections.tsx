import Link from "next/link";

export function ProofBar() {
  return (
    <div className="border-y border-line bg-card/50">
      <div className="mx-auto grid max-w-6xl grid-cols-2 gap-6 px-5 py-8 text-center sm:grid-cols-4">
        {[
          // Every number here has to be one we can point at. Measured round trip
          // from a real Mac to the engine and back on a short dictation:
          //   2026-08-14  16.7s   whisper, full 30s encoder window every request
          //   2026-08-14   3.0s   whisper, encoder window sized per request
          //   2026-08-15   0.47s, 0.61s, 0.59s   parakeet
          // Claimed as "about a second" rather than the raw 0.5s, because the
          // customer also pays for audio conditioning and the paste itself, and
          // that part has not been measured end to end. Re-measure before changing.
          ["~1s", "from stop tap to text, on our engine"],
          ["5", "rewrite modes, one per kind of writing"],
          ["3x", "cheaper than the big-name tool"],
          ["0", "recordings kept, ever, on any disk"],
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

export function FinalCTA() {
  return (
    <section className="mx-auto max-w-4xl px-5 py-28 text-center">
      <h2 className="font-display text-4xl text-ink sm:text-5xl">
        Your keyboard has done enough work for one career
      </h2>
      <p className="mx-auto mt-4 max-w-xl text-muted">
        Fourteen days free, no card to start, and most people are talking to
        their computer within two minutes of creating an account.
      </p>
      <Link
        href="/start"
        className="mt-8 inline-block rounded-xl bg-rosedark px-10 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-rosepress"
      >
        Start talking free
      </Link>
      <p className="mt-4 text-sm text-muted">
        $4.99 a month after that. Cancel by email and it is handled the same day.
      </p>
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
