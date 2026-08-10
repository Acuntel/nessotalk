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
  const paid = plan !== "trial";
  // A live trial is real access. The old build put checkout in front of the
  // download, which meant "fourteen days free" bought you nothing you could
  // actually run.
  const hasAccess = paid || daysLeft > 0;
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
            <span className="rounded-full bg-rose/20 px-3 py-1 text-xs font-semibold text-rosedeep ring-1 ring-rose/40">
              {paid
                ? `${plan} · active`
                : hasAccess
                  ? `Trial · ${daysLeft} days left`
                  : "Trial ended"}
            </span>
            <button onClick={signOut} className="text-sm text-muted hover:text-ink">
              Sign out
            </button>
          </div>
        </div>

        <h1 className="mt-8 font-display text-3xl text-ink">
          {hasAccess ? "Your copy is ready" : "Your trial has ended"}
        </h1>
        <p className="mt-2 text-sm leading-6 text-muted">
          {hasAccess
            ? "The download below has your license inside it, so it works the moment it finishes installing."
            : "Subscribe to switch your copy back on. Everything you set up stays exactly as it was."}
        </p>

        {/* Your key, right at the top. Someone who already installed the free
            download from the home page needs exactly this and nothing else. */}
        <div className="mt-6 rounded-3xl border border-line bg-card p-8">
          <h2 className="font-display text-xl text-ink">Your license key</h2>
          <p className="mt-1 text-sm leading-6 text-muted">
            The download below already carries this key. You only need to copy it
            if you installed from the home page, or you are setting up a second
            computer. Paste it into Settings in the app, under &quot;Your license
            key&quot;, then click Save. Good for one Mac, one Windows PC, and one
            iPhone.
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

        <div className={`mt-6 ${hasAccess ? "" : "pointer-events-none opacity-50"}`}>
          <Walkthrough paid={hasAccess} />
        </div>

        {!paid && (
          <div className="mt-6 rounded-3xl border border-rose/40 bg-card p-8">
            <h2 className="font-display text-xl text-ink">
              {hasAccess
                ? `Keep it after day ${daysLeft > 0 ? daysLeft : 14}`
                : "Subscribe to switch it back on"}
            </h2>
            <p className="mt-2 text-sm leading-6 text-muted">
              $4.99 a month, or $39 a year. Founding price, locked for as long as
              you stay subscribed. Cancel in one click, no conversation.
            </p>
            <button
              onClick={subscribe}
              className="mt-5 w-full rounded-xl bg-rose py-3.5 font-semibold text-white transition hover:bg-rosedeep"
            >
              Subscribe for $4.99 a month
            </button>
          </div>
        )}
      </div>
    </main>
  );
}
