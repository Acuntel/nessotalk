import Link from "next/link";
import Nav from "@/components/Nav";
import WaveformPill from "@/components/WaveformPill";
import Pricing, { FAQ } from "@/components/Pricing";
import {
  ProofBar,
  HowItWorks,
  FeatureGrid,
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
          className="pointer-events-none absolute left-1/2 top-24 h-72 w-[42rem] -translate-x-1/2 rounded-full bg-volt/20 blur-[120px]"
        />
        <span className="fadeup inline-block rounded-full border border-edge bg-panel px-4 py-1.5 text-xs font-medium text-mist">
          For Mac · Local-first · 14 days free
        </span>
        <h1
          className="fadeup mx-auto mt-6 max-w-3xl font-display text-5xl leading-[1.05] text-cream sm:text-7xl"
          style={{ animationDelay: "80ms" }}
        >
          Stop typing.
          <br />
          Start talking.
        </h1>
        <p
          className="fadeup mx-auto mt-6 max-w-xl text-lg text-mist"
          style={{ animationDelay: "160ms" }}
        >
          NessoTalk turns your voice into clean, polished text in any Mac app.
          It runs on your machine, keeps your words yours, and costs a third of
          what the big-name tools charge.
        </p>
        <div
          className="fadeup mt-8 flex items-center justify-center gap-4"
          style={{ animationDelay: "240ms" }}
        >
          <Link
            href="/start"
            className="rounded-xl bg-volt px-8 py-4 text-lg font-semibold text-white shadow-glow transition hover:bg-voltdim"
          >
            Start your free trial
          </Link>
          <a href="#how" className="text-sm text-mist hover:text-cream">
            See how it works
          </a>
        </div>
        <p className="fadeup mt-4 text-xs text-mist" style={{ animationDelay: "300ms" }}>
          No credit card. Set up in about a minute.
        </p>

        <div className="fadeup mt-16" style={{ animationDelay: "360ms" }}>
          <WaveformPill />
        </div>
      </section>

      <ProofBar />
      <HowItWorks />
      <FeatureGrid />
      <Pricing />
      <FAQ />
      <FinalCTA />
      <Footer />
    </main>
  );
}
