import { Reveal } from "@/components/Reveal";
import { Eye, MicOff, CreditCard, UserRound } from "lucide-react";

const POINTS = [
  {
    icon: Eye,
    title: "You can read every line before you run it",
    body: "NessoTalk ships as readable source code rather than a sealed program, so you or anyone you trust can open it and see exactly what it does. Almost no paid software will let you do that, and it is the reason you do not have to take our word for any of the promises on this page.",
  },
  {
    icon: MicOff,
    title: "Your voice never reaches our servers",
    body: "The part that listens to you runs entirely on your own computer. We could not hand your recordings to anyone even if we were asked for them, because we never receive them in the first place. Only the AI rewriting step sends text, and only when you choose it.",
  },
  {
    icon: UserRound,
    title: "There is one person behind this, and you can email him",
    body: "NessoTalk is built by Brady Schwartz. Support is not a ticket queue that answers in four days, it is a reply from the person who wrote the code. If something is broken, you will be talking to the one human who can actually fix it.",
  },
  {
    icon: CreditCard,
    title: "Cancelling takes one click and no conversation",
    body: "You are never charged during the fourteen day trial, and you can end your subscription from your own dashboard whenever you want. There is no phone call, no retention offer, and no form asking why you are leaving.",
  },
];

export function Trust() {
  return (
    <section className="border-y border-line bg-card/60 py-24">
      <div className="mx-auto max-w-5xl px-5">
        <Reveal>
          <h2 className="text-center font-display text-4xl leading-tight text-ink sm:text-5xl">
            You are about to download software from someone you have never met
          </h2>
          <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
            That should give you pause, and we would rather answer it directly
            than hope you do not think about it. Here is exactly why this is
            safe to install.
          </p>
        </Reveal>

        <div className="mt-14 grid gap-6 sm:grid-cols-2">
          {POINTS.map((p, i) => (
            <Reveal key={p.title} delay={i === 0 ? 0 : 1}>
              <div className="h-full rounded-2xl border border-line bg-paper p-7">
                <p.icon className="h-5 w-5 text-rosedeep" />
                <h3 className="mt-4 font-display text-xl leading-snug text-ink">
                  {p.title}
                </h3>
                <p className="mt-3 text-base leading-7 text-muted">{p.body}</p>
              </div>
            </Reveal>
          ))}
        </div>
      </div>
    </section>
  );
}
