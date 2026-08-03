import Link from "next/link";
import Nav from "@/components/Nav";
import WaveformPill from "@/components/WaveformPill";
import Pricing, { FAQ } from "@/components/Pricing";
import { Transform } from "@/components/Transform";
import { Problem } from "@/components/Problem";
import { ScrollTour } from "@/components/ScrollTour";
import { Trust } from "@/components/Trust";
import {
  ProofBar,
  HowItWorks,
  FinalCTA,
  Footer,
} from "@/components/Sections";

export default function Home() {
  return (
    <main className="grain">
      <Nav />

      <section className="relative overflow-hidden px-5 pb-24 pt-36 text-center sm:pt-44">
        <div
          aria-hidden
          className="pointer-events-none absolute left-1/2 top-24 h-72 w-[42rem] -translate-x-1/2 rounded-full bg-rose/20 blur-[120px]"
        />
        <span className="fadeup inline-block rounded-full border border-line bg-card px-4 py-1.5 text-xs font-medium text-muted">
          Mac + Windows · Local-first · 14 days free
        </span>
        <h1
          className="fadeup mx-auto mt-6 max-w-3xl font-display text-5xl leading-[1.05] text-ink sm:text-7xl"
          style={{ animationDelay: "80ms" }}
        >
          Your computer should write down whatever you say
        </h1>
        <p
          className="fadeup mx-auto mt-6 max-w-xl text-lg text-muted"
          style={{ animationDelay: "160ms" }}
        >
          You tap one key and start talking, and a few seconds later your words
          are sitting in whatever you were writing, already cleaned up and
          punctuated. It works in every program on your computer, it does the
          listening on your own machine instead of sending your voice to a
          company, and it costs about a third of what the well-known tools
          charge.
        </p>
        <div
          className="fadeup mt-8 flex items-center justify-center gap-4"
          style={{ animationDelay: "240ms" }}
        >
          <Link
            href="/start"
            className="rounded-xl bg-rose px-8 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-rosedeep"
          >
            Start your free trial
          </Link>
          <a href="#how" className="text-sm text-muted hover:text-ink">
            See how it works
          </a>
        </div>
        <p className="fadeup mt-4 text-xs text-muted" style={{ animationDelay: "300ms" }}>
           Mac · ⊞ Windows · No card · About a minute to set up
        </p>

        <div className="fadeup mt-16" style={{ animationDelay: "360ms" }}>
          <WaveformPill />
        </div>
      </section>

      <ProofBar />
      <Problem />
      <Transform />
      <ScrollTour />
      <HowItWorks />
      <Pricing />
      <Trust />
      <FAQ />
      <FinalCTA />
      <Footer />
    </main>
  );
}
