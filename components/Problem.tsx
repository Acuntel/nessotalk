export function Problem() {
  return (
    <section className="border-y border-line bg-card/50 py-24">
      <div className="mx-auto max-w-5xl px-5">
        <h2 className="text-center font-display text-4xl text-ink sm:text-5xl">
          Most of your day is typing things you could have just said
        </h2>
        <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
          Client emails. Slack replies. Meeting notes. Prompts to your AI tools.
          None of it is hard thinking. It's your fingers trying to keep up with
          a thought you already finished having.
        </p>

        <div className="mt-14 grid gap-6 sm:grid-cols-3">
          {[
            {
              t: "You already know what to say",
              b: "The sentence is done in your head before your hands are a third of the way through it. That gap is where the day goes.",
            },
            {
              t: "So you write less than you should",
              b: "The follow-up gets shorter. The note never gets written. The prompt is three words instead of the paragraph that would have gotten a better answer.",
            },
            {
              t: "Dictation was worse than typing",
              b: "Built-in dictation gives you a wall of ums and no punctuation, so you spend longer cleaning it up than writing it yourself.",
            },
          ].map((c) => (
            <div key={c.t} className="rounded-2xl border border-line bg-paper p-7">
              <h3 className="font-display text-xl text-ink">{c.t}</h3>
              <p className="mt-2 text-sm leading-6 text-muted">{c.b}</p>
            </div>
          ))}
        </div>

        <div className="mx-auto mt-14 max-w-2xl rounded-3xl border border-rose/40 bg-paper p-8 text-center shadow-glow">
          <div className="text-xs font-semibold uppercase tracking-wide text-rose">
            The math on a normal day
          </div>
          <p className="mt-4 text-lg leading-8 text-ink">
            Say you write 2,000 words a day across email, chat, and notes. At a
            fast 45 words a minute that's about{" "}
            <span className="font-semibold">44 minutes</span> of typing. Speaking
            the same 2,000 words takes about{" "}
            <span className="font-semibold">10 minutes</span>.
          </p>
          <p className="mt-4 font-display text-3xl text-ink">
            Roughly half an hour back, every day.
          </p>
          <p className="mt-3 text-sm text-muted">
            That's about 2.8 hours a week. NessoTalk costs less per month than
            one of those hours is worth to almost anyone.
          </p>
        </div>
      </div>
    </section>
  );
}
