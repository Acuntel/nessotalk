import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Lease check-in. The desktop apps POST {key} on launch and every ~12h.
// valid = account exists, not revoked, and (paid plan OR trial still running).
// Revoking someone = set profiles.revoked=true (or let the trial lapse); their
// app disarms on its next check-in.
export async function POST(req: Request) {
  let key = "";
  try {
    const body = await req.json();
    key = String(body.key ?? "").trim();
  } catch {
    // fall through to the invalid response
  }
  if (!/^[0-9a-f-]{36}$/i.test(key)) {
    return NextResponse.json({ valid: false, reason: "bad_key" }, { status: 200 });
  }

  const admin = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
  const { data: p } = await admin
    .from("profiles")
    .select("plan, trial_ends_at, revoked")
    .eq("license_key", key)
    .maybeSingle();

  if (!p) return NextResponse.json({ valid: false, reason: "unknown" }, { status: 200 });
  if (p.revoked) return NextResponse.json({ valid: false, reason: "revoked" }, { status: 200 });

  const trialLive = p.trial_ends_at ? new Date(p.trial_ends_at).getTime() > Date.now() : false;
  const valid = p.plan !== "trial" || trialLive;
  return NextResponse.json(
    { valid, plan: p.plan, trial_ends_at: p.trial_ends_at, reason: valid ? "" : "expired" },
    { status: 200 }
  );
}
