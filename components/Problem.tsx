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
              t: "You have already finished the thought",
              b: "The whole sentence is finished in your head before your hands are even a third of the way through typing it, and that gap between thinking and typing is where an enormous amount of your day quietly disappears.",
            },
            {
              t: "So you end up writing less than you meant to",
              b: "The follow-up email gets shorter than it should be, the note from the meeting never actually gets written down, and the prompt you give your AI tool is three words when a full paragraph would have gotten you a much better answer.",
            },
            {
              t: "The dictation you have tried before made things worse",
              b: "The dictation built into your computer hands you a wall of text with every um still in it and no punctuation anywhere, so you spend longer fixing it than you would have spent just typing the thing yourself.",
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
            That is roughly half an hour handed back to you every single day
          </p>
          <p className="mt-3 text-sm text-muted">
            That works out to about two and a half hours a week, and NessoTalk costs less for an entire month than a single one of those hours is worth to almost anybody.
          </p>
        </div>
      </div>
    </section>
  );
}
