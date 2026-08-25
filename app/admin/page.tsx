"use client";

import { useCallback, useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/client";

// The one admin surface. Everyone signs in the same way; this page simply
// returns "admin only" for every account not in ADMIN_EMAILS, so customers
// never see anything here even if they find the URL.

type Machine = { platform: string; last_seen: string | null };
type AdminUser = {
  id: string;
  email: string;
  plan: string;
  trial_ends_at: string | null;
  revoked: boolean;
  created_at: string;
  license_key: string;
  machines: Machine[];
  trial_live: boolean;
};
type Overview = {
  stats: {
    total: number;
    pro: number;
    trial_active: number;
    trial_expired: number;
    revoked: number;
    activated_machines: number;
  };
  users: AdminUser[];
};

function statusOf(u: AdminUser) {
  if (u.revoked) return { label: "Revoked", cls: "bg-red-100 text-red-700" };
  if (u.plan === "pro") return { label: "Pro", cls: "bg-emerald-100 text-emerald-700" };
  if (u.trial_live) return { label: "Trial", cls: "bg-amber-100 text-amber-700" };
  return { label: "Trial ended", cls: "bg-ink/10 text-muted" };
}

export default function AdminPage() {
  const [state, setState] = useState<"loading" | "signin" | "denied" | "ok">("loading");
  const [data, setData] = useState<Overview | null>(null);
  const [busy, setBusy] = useState("");

  const load = useCallback(async () => {
    const { data: s } = await supabaseBrowser().auth.getSession();
    const token = s.session?.access_token;
    if (!token) return setState("signin");
    const res = await fetch("/api/admin", { headers: { authorization: `Bearer ${token}` } });
    if (res.status === 403) return setState("denied");
    setData(await res.json());
    setState("ok");
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  async function act(userId: string, action: string) {
    setBusy(userId + action);
    const { data: s } = await supabaseBrowser().auth.getSession();
    await fetch("/api/admin", {
      method: "POST",
      headers: {
        authorization: `Bearer ${s.session?.access_token}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({ user_id: userId, action }),
    });
    setBusy("");
    load();
  }

  if (state === "loading") {
    return <main className="grid min-h-screen place-items-center text-muted">Loading…</main>;
  }
  if (state === "signin") {
    return (
      <main className="grid min-h-screen place-items-center px-5 text-center">
        <div>
          <p className="text-lg text-ink">Sign in first, then come back to /admin.</p>
          <a href="/start?mode=signin" className="mt-4 inline-block rounded-xl bg-rosedark px-6 py-3 font-semibold text-white">
            Sign in
          </a>
        </div>
      </main>
    );
  }
  if (state === "denied" || !data) {
    return (
      <main className="grid min-h-screen place-items-center px-5 text-center text-muted">
        <p>This page belongs to the NessoTalk admin account.</p>
      </main>
    );
  }

  const tiles: [string, number][] = [
    ["Total accounts", data.stats.total],
    ["Paying (Pro)", data.stats.pro],
    ["Active trials", data.stats.trial_active],
    ["Expired trials", data.stats.trial_expired],
    ["Revoked", data.stats.revoked],
    ["Activated devices", data.stats.activated_machines],
  ];

  return (
    <main className="mx-auto max-w-6xl px-5 py-12">
      <div className="flex items-baseline justify-between">
        <h1 className="font-display text-3xl text-ink">NessoTalk Admin</h1>
        <a href="/app" className="text-sm text-muted hover:text-ink">Back to dashboard</a>
      </div>

      <div className="mt-8 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-6">
        {tiles.map(([label, n]) => (
          <div key={label} className="rounded-2xl border border-line bg-card p-4">
            <div className="font-display text-3xl text-ink">{n}</div>
            <div className="mt-1 text-xs text-muted">{label}</div>
          </div>
        ))}
      </div>

      <div className="mt-10 overflow-x-auto rounded-2xl border border-line bg-card">
        <table className="w-full min-w-[760px] text-left text-sm">
          <thead>
            <tr className="border-b border-line text-xs uppercase tracking-wide text-muted">
              <th className="px-4 py-3">Account</th>
              <th className="px-4 py-3">Status</th>
              <th className="px-4 py-3">Trial ends</th>
              <th className="px-4 py-3">Devices</th>
              <th className="px-4 py-3">Joined</th>
              <th className="px-4 py-3">Actions</th>
            </tr>
          </thead>
          <tbody>
            {data.users.map((u) => {
              const s = statusOf(u);
              return (
                <tr key={u.id} className="border-b border-line/60">
                  <td className="px-4 py-3">
                    <div className="font-medium text-ink">{u.email}</div>
                    <div className="font-mono text-xs text-muted">{u.license_key.slice(0, 8)}…</div>
                  </td>
                  <td className="px-4 py-3">
                    <span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${s.cls}`}>{s.label}</span>
                  </td>
                  <td className="px-4 py-3 text-muted">
                    {u.trial_ends_at ? new Date(u.trial_ends_at).toLocaleDateString() : "n/a"}
                  </td>
                  <td className="px-4 py-3 text-muted">
                    {u.machines.length === 0 ? "none" : u.machines.map((m) => m.platform).join(", ")}
                  </td>
                  <td className="px-4 py-3 text-muted">{new Date(u.created_at).toLocaleDateString()}</td>
                  <td className="px-4 py-3">
                    <div className="flex flex-wrap gap-2">
                      {u.revoked ? (
                        <button
                          onClick={() => act(u.id, "restore")}
                          disabled={busy !== ""}
                          className="rounded-lg bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40"
                        >
                          Restore
                        </button>
                      ) : (
                        <button
                          onClick={() => act(u.id, "revoke")}
                          disabled={busy !== ""}
                          className="rounded-lg bg-red-600 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-40"
                        >
                          Revoke
                        </button>
                      )}
                      {u.plan !== "pro" && (
                        <button
                          onClick={() => act(u.id, "make_pro")}
                          disabled={busy !== ""}
                          className="rounded-lg bg-ink px-3 py-1.5 text-xs font-semibold text-paper disabled:opacity-40"
                        >
                          Make Pro
                        </button>
                      )}
                      {u.plan === "pro" && (
                        <button
                          onClick={() => act(u.id, "make_trial")}
                          disabled={busy !== ""}
                          className="rounded-lg border border-line px-3 py-1.5 text-xs font-semibold text-ink disabled:opacity-40"
                        >
                          Back to Trial
                        </button>
                      )}
                      {u.machines.length > 0 && (
                        <button
                          onClick={() => {
                            if (
                              confirm(
                                `Release ${u.machines.length} activated machine${u.machines.length === 1 ? "" : "s"} for ${u.email}?\n\nUse this when someone buys a new computer. Their next dictation claims the freed seat automatically.`
                              )
                            )
                              act(u.id, "unbind");
                          }}
                          disabled={busy !== ""}
                          className="rounded-lg border border-line px-3 py-1.5 text-xs font-semibold text-ink disabled:opacity-40"
                          title="Free this licence's machine seats so the customer can install on a new computer"
                        >
                          Unbind {u.machines.length}
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <p className="mt-4 text-xs text-muted">
        Revoke cuts a customer off on their next dictation (the engine refuses within 10 minutes,
        the app disarms within 12 hours). Restore brings them back within a minute.
      </p>
    </main>
  );
}
