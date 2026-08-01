import { ArrowRight } from "lucide-react";

const RAW =
  "um so basically tell paul the uh the quote is ready, its gonna be like 4 grand, no wait, 4500 with the water damage part and um we can start tuesday if he signs tonight";

const CLEAN =
  "Hey Paul, your quote is ready: $4,500 including the water damage work. We can start Tuesday if you sign tonight.";

export function Transform() {
  return (
    <section className="mx-auto max-w-6xl px-5 py-24">
      <h2 className="text-center font-display text-4xl text-cream sm:text-5xl">
        You ramble. It writes.
      </h2>
      <p className="mx-auto mt-4 max-w-xl text-center text-mist">
        Say it however it comes out. NessoTalk handles the ums, the false
        starts, and the "no wait" corrections.
      </p>
      <div className="mt-12 grid items-center gap-6 lg:grid-cols-[1fr_auto_1fr]">
        <div className="rounded-2xl border border-edge bg-panel/60 p-6">
          <div className="text-xs font-semibold uppercase tracking-wide text-mist">
            What you said
          </div>
          <p className="mt-3 font-mono text-sm leading-7 text-mist">{RAW}</p>
        </div>
        <ArrowRight className="mx-auto h-8 w-8 rotate-90 text-volt lg:rotate-0" />
        <div className="rounded-2xl border border-volt/40 bg-panel p-6 shadow-glow">
          <div className="text-xs font-semibold uppercase tracking-wide text-volt">
            What got pasted
          </div>
          <p className="mt-3 text-base leading-7 text-cream">{CLEAN}</p>
        </div>
      </div>

      <div className="mx-auto mt-16 max-w-3xl">
        <div className="flex items-center gap-4">
          <span className="w-28 shrink-0 text-right text-sm text-mist">Typing</span>
          <div className="h-9 flex-1 overflow-hidden rounded-lg bg-panel">
            <div className="flex h-full w-[22%] items-center justify-end rounded-lg bg-white/15 pr-3 text-xs font-semibold text-mist">
              45 wpm
            </div>
          </div>
        </div>
        <div className="mt-3 flex items-center gap-4">
          <span className="w-28 shrink-0 text-right text-sm text-cream">NessoTalk</span>
          <div className="h-9 flex-1 overflow-hidden rounded-lg bg-panel">
            <div className="flex h-full w-full items-center justify-end rounded-lg bg-volt pr-3 text-xs font-bold text-white">
              200+ wpm
            </div>
          </div>
        </div>
        <p className="mt-4 text-center text-xs text-mist">
          You already talk this fast. Now your writing keeps up.
        </p>
      </div>
    </section>
  );
}
