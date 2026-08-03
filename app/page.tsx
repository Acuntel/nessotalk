import Link from "next/link";
import Nav from "@/components/Nav";
import Hero from "@/components/Hero";
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

      <Hero />

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
