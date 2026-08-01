"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Copy, Check, LogOut } from "lucide-react";
import { supabaseBrowser } from "@/lib/supabase/client";

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
  const [entered, setEntered] = useState(false);
  const [copied, setCopied] = useState(false);
  const [note, setNote] = useState("");

  useEffect(() => {
    if (localStorage.getItem("nt_entered") === "1") setEntered(true);
  }, []);

  function start() {
    localStorage.setItem("nt_entered", "1");
    setEntered(true);
  }

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

  if (!entered) {
    return (
      <main className="grain flex min-h-screen flex-col items-center justify-center px-5 text-center">
        <span className="flex h-10 items-end gap-[3px]">
          {[14, 30, 19, 36, 16].map((h, i) => (
            <span key={i} className="w-[4px] rounded-full bg-volt" style={{ height: `${h}px` }} />
          ))}
        </span>
        <h1 className="mt-6 font-display text-4xl text-cream sm:text-5xl">
          Ready when you are.
        </h1>
        <button
          onClick={start}
          className="mt-8 rounded-xl bg-volt px-12 py-5 text-xl font-semibold text-white shadow-glow transition hover:bg-voltdim"
        >
          Start your 14-day trial
        </button>
        <p className="mt-3 text-xs text-mist">No card. It's already yours for two weeks.</p>
        <button onClick={signOut} className="mt-10 flex items-center gap-1.5 text-sm text-mist hover:text-cream">
          <LogOut className="h-4 w-4" /> Sign out
        </button>
      </main>
    );
  }

  return (
    <main className="grain min-h-screen px-5 py-10">
      <div className="mx-auto max-w-2xl">
        <div className="flex items-center justify-between">
          <Link href="/" className="font-display text-xl font-semibold">NessoTalk</Link>
          <div className="flex items-center gap-4">
            <span className="rounded-full bg-volt/20 px-3 py-1 text-xs font-semibold text-volt ring-1 ring-volt/40">
              {plan === "trial" ? `Trial · ${daysLeft} days left` : plan}
            </span>
            <button onClick={signOut} className="text-sm text-mist hover:text-cream">Sign out</button>
          </div>
        </div>

        <div className="mt-10 rounded-3xl border border-edge bg-panel p-8">
          <h1 className="font-display text-2xl text-cream">1. Download it</h1>
          <div className="mt-4 grid grid-cols-2 gap-3">
            <a
              href="/downloads/nessotalk-mac-beta.zip"
              className="rounded-xl bg-cream py-3.5 text-center text-sm font-semibold text-ink transition hover:bg-white"
            >
               Mac
            </a>
            <a
              href="/downloads/nessotalk-windows-beta.zip"
              className="rounded-xl bg-cream py-3.5 text-center text-sm font-semibold text-ink transition hover:bg-white"
            >
              ⊞ Windows
            </a>
          </div>
          <p className="mt-3 text-xs leading-5 text-mist">
            Mac: unzip, then run ./install.sh with your key below. Windows:
            unzip, run setup.ps1. Both are beta builds; the installer walks you
            through the one-time permissions.
          </p>
        </div>

        <div className="mt-6 rounded-3xl border border-edge bg-panel p-8">
          <h1 className="font-display text-2xl text-cream">2. Your license key</h1>
          <p className="mt-1 text-sm text-mist">
            The app checks in with this key. It stops working if your trial ends
            or your subscription lapses, and picks right back up when you're
            active again.
          </p>
          <button
            onClick={copyKey}
            className="mt-4 flex w-full items-center justify-between rounded-xl border border-edge bg-ink px-4 py-3 font-mono text-sm text-cream hover:border-volt"
          >
            <span className="truncate">{licenseKey}</span>
            {copied ? <Check className="h-4 w-4 shrink-0 text-volt" /> : <Copy className="h-4 w-4 shrink-0 text-mist" />}
          </button>
        </div>

        <div className="mt-6 rounded-3xl border border-volt/40 bg-panel p-8">
          <h1 className="font-display text-2xl text-cream">3. Keep it after the trial</h1>
          <p className="mt-1 text-sm text-mist">
            $4.99/mo, founding price locked forever. The other guys charge $15.
          </p>
          <button
            onClick={subscribe}
            className="mt-4 w-full rounded-xl bg-volt py-3.5 font-semibold text-white transition hover:bg-voltdim"
          >
            Subscribe: $4.99/mo
          </button>
          {note && <p className="mt-3 text-xs text-mist">{note}</p>}
        </div>
      </div>
    </main>
  );
}
