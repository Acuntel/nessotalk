import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Admin API. There is exactly ONE admin: Brady. Everyone else is a normal
// Nesso account and gets a 403 here no matter what they try.
//
// Admin-ness is decided by ADMIN_EMAILS (comma separated, set in Vercel env),
// checked against the caller's authenticated Supabase session. It lives in
// env on purpose: a profiles.is_admin column could be flipped by a user
// through the own-row RLS update policy, while env can only change with a
// deploy.
export const dynamic = "force-dynamic";

function service() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
}

async function adminEmail(req: Request): Promise<string | null> {
  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return null;
  const { data } = await service().auth.getUser(token);
  const email = data.user?.email?.toLowerCase() ?? "";
  const allowed = (process.env.ADMIN_EMAILS ?? "")
    .split(",")
    .map((e) => e.trim().toLowerCase())
    .filter(Boolean);
  return email && allowed.includes(email) ? email : null;
}

export async function GET(req: Request) {
  if (!(await adminEmail(req))) {
    return NextResponse.json({ error: "admin_only" }, { status: 403 });
  }
  const db = service();
  const { data: profiles } = await db
    .from("profiles")
    .select("id, email, plan, trial_ends_at, revoked, created_at, license_key, seat_limit, stripe_customer_id")
    .order("created_at", { ascending: false });
  const { data: machines } = await db
    .from("machines")
    .select("license_key, platform, machine_id, last_seen");

  const byLicense = new Map<string, { platform: string; last_seen: string | null }[]>();
  for (const m of machines ?? []) {
    const list = byLicense.get(m.license_key) ?? [];
    list.push({ platform: m.platform, last_seen: m.last_seen ?? null });
    byLicense.set(m.license_key, list);
  }

  const now = Date.now();
  const users = (profiles ?? []).map((p) => ({
    ...p,
    machines: byLicense.get(p.license_key) ?? [],
    trial_live: p.trial_ends_at ? new Date(p.trial_ends_at).getTime() > now : false,
  }));

  const stats = {
    total: users.length,
    pro: users.filter((u) => u.plan === "pro" && !u.revoked).length,
    trial_active: users.filter((u) => u.plan === "trial" && u.trial_live && !u.revoked).length,
    trial_expired: users.filter((u) => u.plan === "trial" && !u.trial_live && !u.revoked).length,
    revoked: users.filter((u) => u.revoked).length,
    activated_machines: (machines ?? []).length,
  };

  return NextResponse.json({ stats, users });
}

const ACTIONS: Record<string, Record<string, unknown>> = {
  revoke: { revoked: true },
  restore: { revoked: false },
  make_pro: { plan: "pro", revoked: false },
  make_trial: { plan: "trial" },
};

export async function POST(req: Request) {
  const admin = await adminEmail(req);
  if (!admin) return NextResponse.json({ error: "admin_only" }, { status: 403 });

  let userId = "";
  let action = "";
  try {
    const body = await req.json();
    userId = String(body.user_id ?? "");
    action = String(body.action ?? "");
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }
  const patch = ACTIONS[action];
  if (!patch || !userId) return NextResponse.json({ error: "bad_action" }, { status: 400 });

  const { error } = await service().from("profiles").update(patch).eq("id", userId);
  if (error) return NextResponse.json({ error: "update_failed" }, { status: 500 });
  return NextResponse.json({ ok: true });
}
