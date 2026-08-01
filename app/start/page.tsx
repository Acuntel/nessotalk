"use client";

import { Suspense, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import Link from "next/link";
import { supabaseBrowser } from "@/lib/supabase/client";

function StartForm() {
  const router = useRouter();
  const params = useSearchParams();
  const [mode, setMode] = useState<"signup" | "signin">(
    params.get("mode") === "signin" ? "signin" : "signup"
  );
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    const supabase = supabaseBrowser();
    const { error } =
      mode === "signup"
        ? await supabase.auth.signUp({ email, password })
        : await supabase.auth.signInWithPassword({ email, password });
    if (error) {
      setError(error.message);
      setBusy(false);
      return;
    }
    router.push("/app");
    router.refresh();
  }

  return (
    <main className="grain flex min-h-screen items-center justify-center px-5">
      <div className="w-full max-w-md">
        <Link href="/" className="mb-8 flex items-center justify-center gap-2">
          <span className="flex h-7 items-end gap-[2.5px]">
            {[10, 22, 14, 26, 12].map((h, i) => (
              <span key={i} className="w-[3px] rounded-full bg-volt" style={{ height: `${h}px` }} />
            ))}
          </span>
          <span className="font-display text-2xl font-semibold">NessoTalk</span>
        </Link>

        <div className="rounded-3xl border border-edge bg-panel p-8 shadow-pill">
          <h1 className="font-display text-2xl text-cream">
            {mode === "signup" ? "Start your 14-day free trial" : "Welcome back"}
          </h1>
          <p className="mt-1 text-sm text-mist">
            {mode === "signup"
              ? "No card. Your trial starts the second you're in."
              : "Sign in to your dashboard."}
          </p>

          <form onSubmit={submit} className="mt-6 space-y-4">
            <input
              type="email"
              required
              placeholder="you@email.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-xl border border-edge bg-ink px-4 py-3 text-cream placeholder-mist outline-none focus:border-volt"
            />
            <input
              type="password"
              required
              minLength={6}
              placeholder="Password (6+ characters)"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-xl border border-edge bg-ink px-4 py-3 text-cream placeholder-mist outline-none focus:border-volt"
            />
            {error && <p className="text-sm text-red-400">{error}</p>}
            <button
              type="submit"
              disabled={busy}
              className="w-full rounded-xl bg-volt py-3.5 font-semibold text-white transition hover:bg-voltdim disabled:opacity-60"
            >
              {busy
                ? "One second..."
                : mode === "signup"
                ? "Create account"
                : "Sign in"}
            </button>
          </form>

          <button
            onClick={() => setMode(mode === "signup" ? "signin" : "signup")}
            className="mt-4 w-full text-center text-sm text-mist hover:text-cream"
          >
            {mode === "signup"
              ? "Already have an account? Sign in"
              : "New here? Start your free trial"}
          </button>
        </div>
      </div>
    </main>
  );
}

export default function StartPage() {
  return (
    <Suspense>
      <StartForm />
    </Suspense>
  );
}
