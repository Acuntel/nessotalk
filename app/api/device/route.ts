import { NextResponse } from "next/server";
import { createHash, randomBytes } from "crypto";
import { adminDb } from "@/lib/db";
import { accessFor } from "@/lib/access";

// Device authorisation with PKCE. This is what replaces "copy your licence key
// out of a web page and paste it into Settings".
//
// The flow, which is the same shape Wispr Flow uses:
//   1. The app invents a random device_code and a code_verifier, keeps the
//      verifier in memory, and sends only its SHA-256 hash (code_challenge).
//   2. The app opens the browser at /activate?device_code=...
//   3. The person signs in there, where their password manager already works,
//      and the page binds the device_code to their account.
//   4. The page redirects to nessotalk://auth?code=..., which macOS routes to
//      the running app.
//   5. The app posts that code back WITH the verifier and receives the licence
//      key over HTTPS.
//
// Why the verifier matters: any app on the machine can register the same URL
// scheme, so the deep link must not carry anything secret. An intercepted
// nessotalk:// URL is worthless without the verifier, which never left the
// process that started the flow.
export const dynamic = "force-dynamic";

const TEN_MINUTES = 10 * 60 * 1000;

function sha256b64url(s: string) {
  return createHash("sha256").update(s).digest("base64url");
}

export async function POST(req: Request) {
  let action = "";
  let body: Record<string, string> = {};
  try {
    body = await req.json();
    action = String(body.action ?? "");
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }
  const db = adminDb();

  // --- step 1: the app starts a flow -------------------------------------
  if (action === "start") {
    const challenge = String(body.code_challenge ?? "");
    if (!/^[A-Za-z0-9_-]{43}$/.test(challenge)) {
      return NextResponse.json({ error: "bad_challenge" }, { status: 400 });
    }
    const deviceCode = randomBytes(24).toString("base64url");
    const { error } = await db
      .from("device_auth")
      .insert({ device_code: deviceCode, code_challenge: challenge });
    if (error) return NextResponse.json({ error: "start_failed" }, { status: 500 });

    const origin = new URL(req.url).origin;
    return NextResponse.json({
      device_code: deviceCode,
      verify_url: `${origin}/activate?device_code=${encodeURIComponent(deviceCode)}`,
    });
  }

  // --- step 5: the app redeems the one-time code --------------------------
  if (action === "claim") {
    const code = String(body.code ?? "");
    const verifier = String(body.code_verifier ?? "");
    if (!code || !verifier) {
      return NextResponse.json({ error: "bad_request" }, { status: 400 });
    }

    const { data: row } = await db
      .from("device_auth")
      .select("device_code, code_challenge, user_id, claimed, created_at")
      .eq("auth_code", code)
      .maybeSingle();

    // Every failure below is deliberately the same message. Telling an attacker
    // which part they got wrong is free help.
    const deny = () => NextResponse.json({ error: "invalid_code" }, { status: 400 });
    if (!row || row.claimed || !row.user_id) return deny();
    if (Date.now() - Date.parse(row.created_at) > TEN_MINUTES) return deny();
    if (sha256b64url(verifier) !== row.code_challenge) return deny();

    // Single use. Burn it before handing anything back, so a replay that races
    // this request loses.
    const { data: burned } = await db
      .from("device_auth")
      .update({ claimed: true })
      .eq("auth_code", code)
      .eq("claimed", false)
      .select("device_code");
    if (!burned || burned.length === 0) return deny();

    const { data: profile } = await db
      .from("profiles")
      .select("license_key, plan, trial_ends_at, revoked, email")
      .eq("id", row.user_id)
      .maybeSingle();
    if (!profile?.license_key) return deny();

    const verdict = accessFor(profile);
    return NextResponse.json({
      license_key: profile.license_key,
      email: profile.email,
      plan: profile.plan,
      // The app shows this, but never enforces on it. Enforcement stays with
      // /api/license and the engine, which are the only things that can be
      // trusted to say no.
      active: verdict.ok,
      reason: verdict.ok ? "" : verdict.reason,
    });
  }

  return NextResponse.json({ error: "bad_action" }, { status: 400 });
}
