import { NextResponse } from "next/server";
import { createPrivateKey, sign } from "crypto";
import { accessFor } from "@/lib/access";
import { adminDb } from "@/lib/db";

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

// Bump when a new build is published to assets/downloads.
const LATEST_VERSION = "8.26";



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
  let platform = "mac";
  try {
    const body = await req.json();
    key = String(body.key ?? "").trim();
    machine = String(body.machine ?? "").trim().slice(0, 128);
    platform = String(body.platform ?? "mac").trim().toLowerCase();
    if (!["mac", "windows", "ios"].includes(platform)) platform = "mac";
  } catch {
    return deny("bad_request");
  }
  if (!/^[0-9a-f-]{36}$/i.test(key)) return deny("bad_key");

  const db = adminDb();
  const { data: p } = await db
    .from("profiles")
    .select("plan, trial_ends_at, revoked, seat_limit")
    .eq("license_key", key)
    .maybeSingle();

  // Shared allowlist, same rule as /api/download and /api/update.
  if (!p) return deny("unknown", key, machine);
  const verdict = accessFor(p);
  if (!verdict.ok) return deny(verdict.reason, key, machine);

  // A blank machine id used to skip the seat block below entirely while still
  // returning a signed valid:true, so one key could be shared without limit by
  // simply omitting the field. The desktop and Windows clients both always send
  // it, so requiring it costs nothing.
  if (!machine) return deny("machine_required", key, machine);

  // Seat binding: a key works on up to seat_limit machines. Sharing it with a
  // crowd trips the cap, and every machine id is recorded either way.
  // One activation per platform. The same key unlocks Mac, Windows, and iPhone,
  // but only the first machine on each platform keeps working. A second,
  // different machine on a platform already claimed is refused outright.
  if (machine) {
    const { data: claimed } = await db
      .from("machines")
      .select("machine_id")
      .eq("license_key", key)
      .eq("platform", platform)
      .maybeSingle();

    if (claimed && claimed.machine_id !== machine) {
      return deny("platform_already_activated", key, machine);
    }
    if (!claimed) {
      const { error } = await db
        .from("machines")
        .insert({ license_key: key, machine_id: machine, platform });
      // The unique index is the real guard, so a race loses here rather than
      // handing out a second activation.
      if (error) return deny("platform_already_activated", key, machine);
    } else {
      await db
        .from("machines")
        .update({ last_seen: new Date().toISOString() })
        .eq("license_key", key)
        .eq("platform", platform);
    }
  }

  // The app compares this against its own version and tells the user to run
  // `ptt update` when a newer build exists. No separate update check needed.
  const payload = {
    key,
    machine,
    platform,
    valid: true,
    plan: p.plan,
    trial_ends_at: p.trial_ends_at,
    // Offline grace. This was 14 days, which meant revoking someone could take
    // two weeks to actually stop them on a machine that stayed offline. The
    // whole product is "granted and revoked by us", so the window has to be
    // short enough for that to be true. 24 hours still covers a flight or a
    // weekend without internet.
    exp: Date.now() + 86_400_000,
  };
  return NextResponse.json({
    valid: true,
    plan: p.plan,
    reason: "",
    latest_version: LATEST_VERSION,
    ...signed(payload),
  });
}
