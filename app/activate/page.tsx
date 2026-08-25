"use client";

import { Suspense, useCallback, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/client";

// The one page the app sends people to. It exists so that signing in happens in
// a real browser, where a password manager and any existing session already
// work, and then hands the result back to the app through nessotalk://.
//
// If the person is already signed in, which they usually are because they just
// created an account to download the app, this page finishes on its own and
// they never touch anything.

type Phase = "checking" | "signin" | "binding" | "done" | "error";

function Activate() {
  const params = useSearchParams();
  const deviceCode = params.get("device_code") ?? "";
  const [phase, setPhase] = useState<Phase>("checking");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [mode, setMode] = useState<"signup" | "signin">("signin");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const bind = useCallback(async () => {
    setPhase("binding");
    const res = await fetch("/api/device/bind", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ device_code: deviceCode }),
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok || !json.redirect) {
      setError(
        json.error === "expired"
          ? "This link has expired. Open NessoTalk and click Sign in again."
          : "Something went wrong. Open NessoTalk and click Sign in again."
      );
      setPhase("error");
      return;
    }
    setPhase("done");
    // Handing off to the app. macOS routes this to the running NessoTalk.
    window.location.href = json.redirect;
  }, [deviceCode]);

  useEffect(() => {
    if (!deviceCode) {
      setError("This link is missing its code. Open NessoTalk and click Sign in again.");
      setPhase("error");
      return;
    }
    supabaseBrowser()
      .auth.getSession()
      .then(({ data }) => {
        if (data.session) bind();
        else setPhase("signin");
      });
  }, [deviceCode, bind]);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const supabase = supabaseBrowser();
    const { error } =
      mode === "signup"
        ? await supabase.auth.signUp({ email, password })
        : await supabase.auth.signInWithPassword({ email, password });
    setBusy(false);
    if (error) return setError(error.message);
    bind();
  }

  return (
    <main className="grain flex min-h-screen items-center justify-center px-5">
      <div className="w-full max-w-md text-center">
        <Link href="/" className="font-display text-2xl font-semibold text-ink">
          NessoTalk
        </Link>

        {(phase === "checking" || phase === "binding") && (
          <p className="mt-10 text-muted">Connecting your account…</p>
        )}

        {phase === "done" && (
          <div className="mt-10">
            <h1 className="font-display text-3xl text-ink">You are connected</h1>
            <p className="mt-3 text-sm leading-6 text-muted">
              NessoTalk has your account and is ready on your Mac. You can close
              this tab.
            </p>
            <p className="mt-6 text-xs text-muted">
              Nothing happened? Make sure NessoTalk is running, then{" "}
              <button onClick={bind} className="font-semibold text-rosedark underline">
                try again
              </button>
              .
            </p>
          </div>
        )}

        {phase === "signin" && (
          <form onSubmit={submit} className="mt-10 text-left">
            <h1 className="text-center font-display text-3xl text-ink">
              {mode === "signup" ? "Create your account" : "Sign in"}
            </h1>
            <p className="mt-3 text-center text-sm leading-6 text-muted">
              This connects NessoTalk on your Mac. It takes one click and you
              will not need to copy anything.
            </p>
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
              className="mt-6 w-full rounded-xl border border-line bg-card px-4 py-3 text-ink"
            />
            <input
              type="password"
              required
              minLength={8}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              placeholder="Password"
              className="mt-3 w-full rounded-xl border border-line bg-card px-4 py-3 text-ink"
            />
            {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
            <button
              type="submit"
              disabled={busy}
              className="mt-5 w-full rounded-xl bg-rosedark py-3.5 font-semibold text-white transition hover:bg-rosepress disabled:opacity-60"
            >
              {busy ? "One moment…" : "Connect NessoTalk"}
            </button>
            <button
              type="button"
              onClick={() => setMode(mode === "signup" ? "signin" : "signup")}
              className="mt-4 w-full text-center text-sm text-muted hover:text-ink"
            >
              {mode === "signup"
                ? "Already have an account? Sign in"
                : "New here? Create an account"}
            </button>
          </form>
        )}

        {phase === "error" && (
          <div className="mt-10">
            <h1 className="font-display text-2xl text-ink">That did not work</h1>
            <p className="mt-3 text-sm leading-6 text-muted">{error}</p>
          </div>
        )}
      </div>
    </main>
  );
}

export default function ActivatePage() {
  return (
    <Suspense fallback={<main className="grain min-h-screen" />}>
      <Activate />
    </Suspense>
  );
}
