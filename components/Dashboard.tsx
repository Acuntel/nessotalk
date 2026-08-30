"use client";

import { useRouter } from "next/navigation";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/client";

const STRIPE_MONTHLY = "https://buy.stripe.com/00wfZh6AA6Ru6kfcxlgMw00";

export default function Dashboard({
  email,
  uid,
  plan,
  daysLeft,
}: {
  email: string;
  uid: string;
  plan: string;
  daysLeft: number;
}) {
  const router = useRouter();
  // Allowlist, not denylist. `plan !== "trial"` quietly treated any unexpected
  // value as paid, which is the wrong direction to fail in.
  const active = plan === "pro";
  // A live trial is real access. Putting checkout in front of setup meant
  // "fourteen days free" bought you nothing you could actually run.
  const trialLive = !active && daysLeft > 0;
  const hasAccess = active || trialLive;

  async function signOut() {
    await supabaseBrowser().auth.signOut();
    router.push("/");
    router.refresh();
  }


  function subscribe() {
    window.location.href =
      STRIPE_MONTHLY +
      "?prefilled_email=" +
      encodeURIComponent(email) +
      "&client_reference_id=" +
      encodeURIComponent(uid);
  }

  return (
    <main className="grain min-h-screen px-5 py-10">
      <div className="mx-auto max-w-2xl">
        <div className="flex items-center justify-between">
          <Link href="/" className="font-display text-xl font-semibold">
            NessoTalk
          </Link>
          <div className="flex items-center gap-4">
            <span className="rounded-full bg-rose/20 px-3 py-1 text-xs font-semibold text-rosedark ring-1 ring-rose/40">
              {active
                ? "Subscribed"
                : trialLive
                  ? `${daysLeft} ${daysLeft === 1 ? "day" : "days"} left`
                  : "Paused"}
            </span>
            <button onClick={signOut} className="text-sm text-muted hover:text-ink">
              Sign out
            </button>
          </div>
        </div>

        <h1 className="mt-8 font-display text-3xl text-ink">
          {active
            ? "You are all set"
            : trialLive
              ? "You are ready to talk"
              : "Your access is paused"}
        </h1>
        <p className="mt-2 max-w-lg text-sm leading-6 text-muted">
          {hasAccess
            ? "One button, then you are talking. Everything else happens on our side."
            : "Nothing was deleted. Everything you set up is exactly where you left it, and subscribing switches it back on straight away."}
        </p>

        {/* One bright thing to do per state, and nothing dimmed. A greyed-out
            tutorial reads as a page that failed to load rather than as a
            feature you have lost access to, so the locked state simply does not
            render the tutorial at all. */}

        {!hasAccess && (
          <div className="mt-8 rounded-3xl border-2 border-rose bg-card p-8 shadow-glow">
            <h2 className="font-display text-2xl text-ink">
              Switch it back on for $5 a month
            </h2>
            <p className="mt-2 text-sm leading-6 text-muted">
              Founding price, locked for as long as you stay subscribed. It takes
              effect the moment you pay, and you keep everything you already set up.
              Cancel by email and it is handled the same day.
            </p>
            <button
              onClick={subscribe}
              className="mt-6 w-full rounded-xl bg-rosedark py-4 text-lg font-semibold text-white transition hover:bg-rosepress"
            >
              Subscribe for $5 a month
            </button>
          </div>
        )}

        {/* ONE step. The four-step walkthrough that used to live here was the
            friction: a numbered list is a promise that this will take a while,
            and the first real customer read it and left without installing.
            Everything it explained now happens either automatically or inside
            the app, after the first dictation, when it actually means something. */}
        {hasAccess && (
          <div className="mt-8 rounded-3xl border-2 border-rose bg-card p-10 text-center shadow-glow">
            <h2 className="font-display text-2xl text-ink">Install NessoTalk</h2>
            <p className="mx-auto mt-3 max-w-md text-sm leading-6 text-muted">
              It opens by itself and walks you through the two permissions your
              Mac asks for. You will be talking about thirty seconds from now.
            </p>
            <a
              href="/api/download?platform=mac"
              className="mt-7 inline-block rounded-xl bg-rosedark px-12 py-4 text-lg font-semibold text-white transition hover:bg-rosepress"
            >
              Install for Mac
            </a>
            <p className="mt-4 text-xs text-muted">
              Already installed on another Mac? Open NessoTalk there and choose
              Sign in. There is nothing to copy across.
            </p>
          </div>
        )}

        {/* The licence key used to be shown here with instructions for pasting
            it into Settings. There is nothing to paste any more: the install
            carries it, and a second Mac signs in through the browser. Showing a
            key at all invites people to think they have to do something with it. */}

        {/* During a live trial the ask stays quiet and sits last. The customer
            has not felt the product yet, so pushing checkout above setup is how
            you lose them. */}
        {trialLive && (
          <div className="mt-6 rounded-3xl border border-line bg-card p-8">
            <h2 className="font-display text-xl text-ink">
              {daysLeft <= 3
                ? `Only ${daysLeft} ${daysLeft === 1 ? "day" : "days"} left`
                : "Keep it after the free fortnight"}
            </h2>
            <p className="mt-2 text-sm leading-6 text-muted">
              $5 a month, which is about a third of what the well known ones
              charge. Founding price, locked for as long as you stay subscribed.
              Subscribing now does not shorten your free days.
            </p>
            <button
              onClick={subscribe}
              className="mt-5 w-full rounded-xl border border-rosedark bg-transparent py-3.5 font-semibold text-rosedark transition hover:bg-rosedark hover:text-white"
            >
              Subscribe for $5 a month
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
