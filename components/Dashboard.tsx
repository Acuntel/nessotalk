"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { Download, Sparkles, LogOut } from "lucide-react";
import { supabaseBrowser } from "@/lib/supabase/client";

const STRIPE_MONTHLY = "https://buy.stripe.com/00wfZh6AA6Ru6kfcxlgMw00";
const WINDOWS_ZIP =
  "https://github.com/jeremymhayes/ptt-dictate-windows/archive/refs/heads/main.zip";

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
  const [note, setNote] = useState("");

  async function signOut() {
    await supabaseBrowser().auth.signOut();
    router.push("/");
    router.refresh();
  }

  function upgrade(interval: "month" | "year") {
    if (interval === "month") {
      const url =
        STRIPE_MONTHLY +
        "?prefilled_email=" +
        encodeURIComponent(email) +
        "&client_reference_id=" +
        encodeURIComponent(uid);
      window.location.href = url;
      return;
    }
    setNote(
      "Annual checkout opens shortly. Your founding price is locked at $39/yr, and your trial keeps running until then."
    );
  }

  return (
    <main className="grain min-h-screen px-5 py-10">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between">
          <Link href="/" className="flex items-center gap-2">
            <span className="flex h-6 items-end gap-[2px]">
              {[8, 18, 11, 21, 9].map((h, i) => (
                <span key={i} className="w-[3px] rounded-full bg-volt" style={{ height: `${h}px` }} />
              ))}
            </span>
            <span className="font-display text-xl font-semibold">NessoTalk</span>
          </Link>
          <button onClick={signOut} className="flex items-center gap-1.5 text-sm text-mist hover:text-cream">
            <LogOut className="h-4 w-4" /> Sign out
          </button>
        </div>

        <div className="mt-10 rounded-3xl border border-edge bg-panel p-8">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h1 className="font-display text-2xl text-cream">You're in.</h1>
              <p className="mt-1 text-sm text-mist">{email}</p>
            </div>
            <span className="rounded-full bg-volt/20 px-4 py-1.5 text-sm font-semibold text-volt ring-1 ring-volt/40">
              {plan === "trial" ? `Free trial · ${daysLeft} days left` : plan}
            </span>
          </div>
        </div>

        <div className="mt-6 grid gap-6 sm:grid-cols-2">
          <div className="rounded-3xl border border-edge bg-panel p-8">
            <Download className="h-6 w-6 text-volt" />
            <h2 className="mt-3 font-display text-xl text-cream">Get NessoTalk</h2>
            <p className="mt-2 text-sm leading-6 text-mist">
              Pick your platform. Windows beta is downloadable now (unzip, run
              setup.ps1). The Mac beta lands here next; we'll email you the
              moment it's ready.
            </p>
            <div className="mt-5 grid grid-cols-2 gap-3">
              <a
                href={WINDOWS_ZIP}
                className="rounded-xl bg-cream py-3 text-center text-sm font-semibold text-ink transition hover:bg-white"
              >
                Windows beta
              </a>
              <button
                disabled
                className="cursor-not-allowed rounded-xl border border-edge bg-ink py-3 text-sm font-semibold text-mist"
              >
                macOS soon
              </button>
            </div>
          </div>

          <div className="rounded-3xl border border-volt/40 bg-panel p-8">
            <Sparkles className="h-6 w-6 text-volt" />
            <h2 className="mt-3 font-display text-xl text-cream">Founding price</h2>
            <p className="mt-2 text-sm leading-6 text-mist">
              $4.99/mo or $39/yr, locked forever. The other guys charge $15/mo
              for less privacy.
            </p>
            <div className="mt-5 grid grid-cols-2 gap-3">
              <button
                onClick={() => upgrade("month")}
                className="rounded-xl bg-volt py-3 text-sm font-semibold text-white transition hover:bg-voltdim"
              >
                $4.99/mo
              </button>
              <button
                onClick={() => upgrade("year")}
                className="rounded-xl border border-volt/50 py-3 text-sm font-semibold text-volt transition hover:bg-volt/10"
              >
                $39/yr
              </button>
            </div>
          </div>
        </div>

        {note && (
          <p className="mt-6 rounded-2xl border border-edge bg-panel/60 p-4 text-sm text-mist">
            {note}
          </p>
        )}
      </div>
    </main>
  );
}
