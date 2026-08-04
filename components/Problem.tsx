export function Problem() {
  return (
    <section className="border-y border-line bg-card/50 py-24">
      <div className="mx-auto max-w-5xl px-5">
        <h2 className="text-center font-display text-4xl text-ink sm:text-5xl">
          Most of your day is typing things you could have just said
        </h2>
        <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
          Client emails, Slack replies, meeting notes, AI prompts: none of it is
          hard thinking, it is your fingers trying to keep up with a thought you
          already finished.
        </p>

        <div className="mt-14 grid gap-6 sm:grid-cols-3">
          {[
            {
              t: "The thought is already done",
              b: "The sentence is finished in your head long before your hands finish typing it.",
            },
            {
              t: "So you write less than you meant to",
              b: "Follow-ups get shorter, notes never get written, and your AI prompts end up three words long.",
            },
            {
              t: "Built-in dictation made it worse",
              b: "It handed you a wall of text with every um still in it, so you spent longer cleaning up than typing.",
            },
          ].map((c) => (
            <div key={c.t} className="rounded-2xl border border-line bg-paper p-7">
              <h3 className="font-display text-xl text-ink">{c.t}</h3>
              <p className="mt-2 text-sm leading-6 text-muted">{c.b}</p>
            </div>
          ))}
        </div>

        <div className="mx-auto mt-14 max-w-3xl rounded-3xl border border-rose/40 bg-paper p-8 shadow-glow">
          <div className="text-center text-xs font-semibold uppercase tracking-wide text-rose">
            The math on a normal 2,000 word day
          </div>
          <div className="mt-6 grid grid-cols-3 gap-4 text-center">
            <div>
              <div className="font-display text-4xl text-muted sm:text-5xl">
                44<span className="text-xl"> min</span>
              </div>
              <div className="mt-1 text-xs text-muted">typing them at 45 wpm</div>
            </div>
            <div>
              <div className="font-display text-4xl text-ink sm:text-5xl">
                10<span className="text-xl"> min</span>
              </div>
              <div className="mt-1 text-xs text-muted">saying the same words</div>
            </div>
            <div>
              <div className="font-display text-4xl text-rosedeep sm:text-5xl">
                30<span className="text-xl"> min</span>
              </div>
              <div className="mt-1 text-xs text-muted">handed back every day</div>
            </div>
          </div>
          <p className="mt-6 text-center text-sm text-muted">
            That adds up to about two and a half hours every single week.
          </p>
        </div>
      </div>
    </section>
  );
}
