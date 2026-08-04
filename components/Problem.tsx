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

        <div className="mx-auto mt-12 max-w-3xl rounded-3xl border border-rose/40 bg-paper p-8 shadow-glow">
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
