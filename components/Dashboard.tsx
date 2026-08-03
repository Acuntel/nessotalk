"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Copy, Check, LogOut, Lock } from "lucide-react";
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
  const [entered, setEntered] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (localStorage.getItem("nt_entered") === "1") setEntered(true);
  }, []);

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

  // Click 3 of the funnel: one button, straight to checkout.
  if (!entered && !paid) {
    return (
      <main className="grain flex min-h-screen flex-col items-center justify-center px-5 text-center">
        <span className="flex h-10 items-end gap-[3px]">
          {[14, 30, 19, 36, 16].map((h, i) => (
            <span key={i} className="w-[4px] rounded-full bg-rose" style={{ height: `${h}px` }} />
          ))}
        </span>
        <h1 className="mt-6 font-display text-4xl text-ink sm:text-5xl">
          Everything is ready for you
        </h1>
        <p className="mx-auto mt-4 max-w-md text-muted">
          Fourteen days free, then $4.99 a month. Cancel in one click before day
          14 and you are never charged.
        </p>
        <button
          onClick={() => {
            localStorage.setItem("nt_entered", "1");
            setEntered(true);
            subscribe();
          }}
          className="mt-8 rounded-xl bg-rose px-12 py-5 text-xl font-semibold text-white shadow-glow transition hover:bg-rosedeep"
        >
          Start your 14-day trial
        </button>
        <p className="mt-3 text-xs text-muted">
          Card required so your access never interrupts mid-sentence. No charge
          today.
        </p>
        <button
          onClick={signOut}
          className="mt-10 flex items-center gap-1.5 text-sm text-muted hover:text-ink"
        >
          <LogOut className="h-4 w-4" /> Sign out
        </button>
      </main>
    );
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
              {paid ? `${plan} · active` : `Trial · ${daysLeft} days left`}
            </span>
            <button onClick={signOut} className="text-sm text-muted hover:text-ink">
              Sign out
            </button>
          </div>
        </div>

        {!paid && (
          <div className="mt-8 rounded-3xl border border-rose/40 bg-card p-8">
            <div className="flex items-center gap-2 text-rosedeep">
              <Lock className="h-4 w-4" />
              <span className="text-xs font-semibold uppercase tracking-wide">
                One step left
              </span>
            </div>
            <h1 className="mt-3 font-display text-2xl text-ink">
              Start your trial to unlock the download
            </h1>
            <p className="mt-2 text-sm leading-6 text-muted">
              Fourteen days free, then $4.99 a month. Your copy is built for you
              with your license inside it, which is why we set up billing first.
              Cancel any time in one click.
            </p>
            <button
              onClick={subscribe}
              className="mt-5 w-full rounded-xl bg-rose py-3.5 font-semibold text-white transition hover:bg-rosedeep"
            >
              Start 14 days free
            </button>
          </div>
        )}

        <div className={`mt-6 ${paid ? "" : "pointer-events-none opacity-50"}`}>
          <Walkthrough paid={paid} />
        </div>

        <div className="mt-6 rounded-3xl border border-line bg-card p-8">
          <h2 className="font-display text-xl text-ink">Your license key</h2>
          <p className="mt-1 text-sm leading-6 text-muted">
            Already inside your download, so you only need this if you set up a
            second computer. Good for 3 machines.
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
      </div>
    </main>
  );
}
