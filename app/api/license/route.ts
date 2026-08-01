import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { createPrivateKey, sign } from "crypto";

// Lease check-in. Desktop apps POST {key, machine} on launch and every ~12h.
//
// The response is SIGNED (Ed25519). The app verifies the signature against a
// public key compiled into it, so pointing nesso.tech at a fake local server
// and returning {"valid":true} does not work: the attacker cannot produce a
// signature without the private key, which never leaves this server.
//
// Revoking someone = profiles.revoked = true (or let the trial lapse).
// Sharing a key is bounded by seat_limit distinct machine ids.
export const dynamic = "force-dynamic";

function admin() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
}

function signed(payload: Record<string, unknown>) {
  const body = JSON.stringify(payload);
  const pem = (process.env.LICENSE_PRIVATE_KEY ?? "").replace(/\\n/g, "\n");
  if (!pem) return { token: body, sig: "" };
  const sig = sign(null, Buffer.from(body), createPrivateKey(pem));
  return { token: Buffer.from(body).toString("base64"), sig: sig.toString("base64") };
}

function deny(reason: string, key = "", machine = "") {
  return NextResponse.json(
    { valid: false, reason, ...signed({ key, machine, valid: false, reason, exp: Date.now() + 3600_000 }) },
    { status: 200 }
  );
}

export async function POST(req: Request) {
  let key = "";
  let machine = "";
  try {
    const body = await req.json();
    key = String(body.key ?? "").trim();
    machine = String(body.machine ?? "").trim().slice(0, 128);
  } catch {
    return deny("bad_request");
  }
  if (!/^[0-9a-f-]{36}$/i.test(key)) return deny("bad_key");

  const db = admin();
  const { data: p } = await db
    .from("profiles")
    .select("plan, trial_ends_at, revoked, seat_limit")
    .eq("license_key", key)
    .maybeSingle();

  if (!p) return deny("unknown", key, machine);
  if (p.revoked) return deny("revoked", key, machine);

  const trialLive = p.trial_ends_at ? new Date(p.trial_ends_at).getTime() > Date.now() : false;
  if (p.plan === "trial" && !trialLive) return deny("expired", key, machine);

  // Seat binding: a key works on up to seat_limit machines. Sharing it with a
  // crowd trips the cap, and every machine id is recorded either way.
  if (machine) {
    const { data: seats } = await db
      .from("machines")
      .select("machine_id")
      .eq("license_key", key);
    const known = (seats ?? []).some((s) => s.machine_id === machine);
    if (!known && (seats?.length ?? 0) >= (p.seat_limit ?? 3)) {
      return deny("seat_limit", key, machine);
    }
    await db
      .from("machines")
      .upsert(
        { license_key: key, machine_id: machine, last_seen: new Date().toISOString() },
        { onConflict: "license_key,machine_id" }
      );
  }

  const payload = {
    key,
    machine,
    valid: true,
    plan: p.plan,
    trial_ends_at: p.trial_ends_at,
    // Token is good for 14 days offline; after that the app must check in again.
    exp: Date.now() + 14 * 86_400_000,
  };
  return NextResponse.json({ valid: true, plan: p.plan, reason: "", ...signed(payload) });
}
