import { Reveal } from "@/components/Reveal";
import { ShieldCheck, MicOff, CreditCard, UserRound } from "lucide-react";

const POINTS = [
  {
    icon: ShieldCheck,
    title: "Nothing installs without showing you first",
    body: "The installer explains every step before it takes it, and your computer asks for microphone permission in its own words. You can stop it at any point.",
  },
  {
    icon: MicOff,
    title: "Your voice never reaches our servers",
    body: "Transcription and every rewrite mode run entirely on your own computer, so we never receive your recordings or your words at all. The only thing the app ever sends is a yes-or-no license check.",
  },
  {
    icon: UserRound,
    title: "There is one person behind this, and you can email him",
    body: "NessoTalk is built by Brady Schwartz, and support is a reply from the person who wrote the code, not a ticket queue.",
  },
  {
    icon: CreditCard,
    title: "Cancelling takes one click and no conversation",
    body: "You are never charged during the fourteen day trial, and you can cancel from your own dashboard in one click with no retention flow.",
  },
];

export function Trust() {
  return (
    <section className="border-y border-line bg-card/60 py-24">
      <div className="mx-auto max-w-5xl px-5">
        <Reveal>
          <h2 className="text-center font-display text-4xl leading-tight text-ink sm:text-5xl">
            How we handle your voice, your data, and your money
          </h2>
          <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
            Everything sensitive stays on your computer, and everything billing
            related stays in your control.
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
