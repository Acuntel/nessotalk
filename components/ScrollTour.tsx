"use client";

import { Reveal } from "@/components/Reveal";

// A slow, scrolled walkthrough of one real dictation, written for somebody who
// has never used a tool like this and wants to know exactly what happens.
const BEATS = [
  {
    n: "01",
    title: "You are sitting in an email you do not want to type",
    body: "It is the reply you keep putting off, the one that needs about four paragraphs and a number in it. Your cursor is blinking in the message box. You have not typed anything yet, and you already know roughly what the whole thing needs to say.",
    aside: "Nothing is running yet. NessoTalk sits quietly in your menu bar until you ask for it.",
  },
  {
    n: "02",
    title: "You tap one key and simply start talking",
    body: "You tap the key you chose during setup and a small bar appears at the bottom of your screen. It shows a moving line that responds to your voice, so you can see that it is genuinely hearing you, and the words appear on that bar as you say them. You talk the way you would talk to a person, including the parts where you correct yourself.",
    aside: "The listening happens on your own computer. Your voice is never uploaded anywhere.",
  },
  {
    n: "03",
    title: "You choose how you want it written before you finish",
    body: "On that same bar there are three choices you can click while you are still speaking. One gives you your words exactly as you said them. One writes it as a clean, professional message suitable for a client or a colleague. One organizes everything into a structured brief, which is what you want when you are talking to an AI tool. If you never touch them, it uses the setting you picked when you set it up.",
    aside: "You can also tell it, once, how you want it to always sound, and it will write that way from then on.",
  },
  {
    n: "04",
    title: "You tap the key again and the writing is simply there",
    body: "About two seconds later the finished text is sitting in your email exactly where the cursor was. The ums are gone, the sentences are complete, the punctuation is correct, and the place where you said the wrong number and then corrected yourself has quietly become the right number. You read it once and you send it.",
    aside: "If you change your mind mid-sentence, pressing Escape throws the whole recording away and nothing is typed.",
  },
  {
    n: "05",
    title: "You realize you just did four minutes of work in forty seconds",
    body: "That is the entire product. There is no separate window to open, no file to manage, and nothing to copy and paste. It behaves the same way in your email, in a document, in a chat message, and in whatever AI tool you use, because as far as your computer is concerned it is simply typing.",
    aside: "Most people stop noticing it is there within about a day, which is the point.",
  },
];

export function ScrollTour() {
  return (
    <section className="mx-auto max-w-4xl px-5 py-24">
      <Reveal>
        <h2 className="text-center font-display text-4xl leading-tight text-ink sm:text-5xl">
          Here is exactly what using it looks like, start to finish
        </h2>
        <p className="mx-auto mt-5 max-w-2xl text-center text-lg leading-8 text-muted">
          If you have never used a dictation tool that works properly, the whole
          idea can sound vague. So here is a single, ordinary use of it, written
          out step by step, with nothing skipped.
        </p>
      </Reveal>

      <div className="mt-16 space-y-14">
        {BEATS.map((b, i) => (
          <Reveal key={b.n} delay={i === 0 ? 0 : 1}>
            <div className="grid gap-5 sm:grid-cols-[auto_1fr]">
              <div className="font-display text-3xl text-rose sm:pt-1">{b.n}</div>
              <div className="border-l border-line pl-6">
                <h3 className="font-display text-2xl leading-snug text-ink">
                  {b.title}
                </h3>
                <p className="mt-3 text-base leading-8 text-muted">{b.body}</p>
                <p className="mt-4 rounded-xl bg-rose/10 px-4 py-3 text-sm leading-6 text-ink">
                  {b.aside}
                </p>
              </div>
            </div>
          </Reveal>
        ))}
      </div>
    </section>
  );
}
