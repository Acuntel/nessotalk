"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Copy, Check, LogOut } from "lucide-react";
import { supabaseBrowser } from "@/lib/supabase/client";
import Walkthrough from "@/components/Walkthrough";

const STRIPE_MONTHLY = "https://buy.stripe.com/00wfZh6AA6Ru6kfcxlgMw00";

export default function Dashboard({
  email,
  uid,
  plan,
  daysLeft,
  licenseKey,
}: {
  email: string;
  uid: string;
  plan: string;
  daysLeft: number;
  licenseKey: string;
}) {
  const router = useRouter();
  // Allowlist, not denylist. `plan !== "trial"` quietly treated any unexpected
  // value as paid, which is the wrong direction to fail in.
  const active = plan === "pro";
  // A live trial is real access. Putting checkout in front of setup meant
  // "fourteen days free" bought you nothing you could actually run.
  const trialLive = !active && daysLeft > 0;
  const hasAccess = active || trialLive;
  const [copied, setCopied] = useState(false);

  async function signOut() {
    await supabaseBrowser().auth.signOut();
    router.push("/");
    router.refresh();
  }

  function copyKey() {
    navigator.clipboard.writeText(licenseKey);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
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
            ? "Your subscription is what does the work. Your words are transcribed on the NessoTalk engine, and the app below is just how you reach it, so there is nothing heavy to install and nothing to activate."
            : "Nothing was deleted. The app, your settings, your dictionary and your key are all exactly where you left them, and subscribing switches them back on straight away."}
        </p>

        {/* One bright thing to do per state, and nothing dimmed. A greyed-out
            tutorial reads as a page that failed to load rather than as a
            feature you have lost access to, so the locked state simply does not
            render the tutorial at all. */}

        {!hasAccess && (
          <div className="mt-8 rounded-3xl border-2 border-rose bg-card p-8 shadow-glow">
            <h2 className="font-display text-2xl text-ink">
              Switch it back on for $4.99 a month
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
              Subscribe for $4.99 a month
            </button>
          </div>
        )}

        {hasAccess && (
          <div className="mt-6">
            <Walkthrough />
          </div>
        )}

        <div className="mt-6 rounded-3xl border border-line bg-card p-8">
          <h2 className="font-display text-xl text-ink">Your license key</h2>
          <p className="mt-1 text-sm leading-6 text-muted">
            This is what your subscription actually is: the key that opens the
            engine.{" "}
            {hasAccess
              ? "The install above already carries it, so you only need to copy it when you are setting up another computer."
              : "It stays yours while your access is paused, and starts working again the moment you subscribe."}{" "}
            To use it on another computer, paste it into Settings in the app,
            under &quot;Your license key&quot;, then click Save. Good for one Mac,
            one Windows PC, and one iPhone.
          </p>
          <button
            onClick={copyKey}
            className="mt-4 flex w-full items-center justify-between rounded-xl border border-line bg-paper px-4 py-3 font-mono text-sm text-ink hover:border-rose"
          >
            <span className="truncate">{licenseKey}</span>
            {copied ? (
              <Check className="h-4 w-4 shrink-0 text-rose" />
            ) : (
              <Copy className="h-4 w-4 shrink-0 text-muted" />
            )}
          </button>
        </div>

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
              $4.99 a month, which is about a third of what the well known ones
              charge. Founding price, locked for as long as you stay subscribed.
              Subscribing now does not shorten your free days.
            </p>
            <button
              onClick={subscribe}
              className="mt-5 w-full rounded-xl border border-rosedark bg-transparent py-3.5 font-semibold text-rosedark transition hover:bg-rosedark hover:text-white"
            >
              Subscribe for $4.99 a month
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
