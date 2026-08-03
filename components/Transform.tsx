import { ArrowRight } from "lucide-react";

const RAW =
  "um so basically tell paul the uh the quote is ready, its gonna be like 4 grand, no wait, 4500 with the water damage part and um we can start tuesday if he signs tonight";

const CLEAN =
  "Hey Paul, your quote is ready: $4,500 including the water damage work. We can start Tuesday if you sign tonight.";

export function Transform() {
  return (
    <section className="mx-auto max-w-6xl px-5 py-24">
      <h2 className="text-center font-display text-4xl text-ink sm:text-5xl">
        You ramble. It writes.
      </h2>
      <p className="mx-auto mt-4 max-w-xl text-center text-muted">
        Say it however it comes out. NessoTalk handles the ums, the false
        starts, and the "no wait" corrections.
      </p>
      <div className="mt-12 grid items-center gap-6 lg:grid-cols-[1fr_auto_1fr]">
        <div className="rounded-2xl border border-line bg-card/60 p-6">
          <div className="text-xs font-semibold uppercase tracking-wide text-muted">
            What you said
          </div>
          <p className="mt-3 font-mono text-sm leading-7 text-muted">{RAW}</p>
        </div>
        <ArrowRight className="mx-auto h-8 w-8 rotate-90 text-rose lg:rotate-0" />
        <div className="rounded-2xl border border-rose/40 bg-card p-6 shadow-glow">
          <div className="text-xs font-semibold uppercase tracking-wide text-rose">
            What got pasted
          </div>
          <p className="mt-3 text-base leading-7 text-ink">{CLEAN}</p>
        </div>
      </div>

      <div className="mx-auto mt-16 max-w-3xl">
        <div className="flex items-center gap-4">
          <span className="w-28 shrink-0 text-right text-sm text-muted">Typing</span>
          <div className="h-9 flex-1 overflow-hidden rounded-lg bg-card">
            <div className="flex h-full w-[22%] items-center justify-end rounded-lg bg-ink/10 pr-3 text-xs font-semibold text-muted">
              45 wpm
            </div>
          </div>
        </div>
        <div className="mt-3 flex items-center gap-4">
          <span className="w-28 shrink-0 text-right text-sm text-ink">NessoTalk</span>
          <div className="h-9 flex-1 overflow-hidden rounded-lg bg-card">
            <div className="flex h-full w-full items-center justify-end rounded-lg bg-rose pr-3 text-xs font-bold text-white">
              200+ wpm
            </div>
          </div>
        </div>
        <p className="mt-4 text-center text-xs text-muted">
          You already talk this fast. Now your writing keeps up.
        </p>
      </div>
    </section>
  );
}
