import { NextResponse } from "next/server";
import { randomBytes } from "crypto";
import { adminDb } from "@/lib/db";
import { supabaseServer } from "@/lib/supabase/server";

// Step 3 of the device handoff: the signed-in browser binds a waiting
// device_code to this account and mints the one-time code that travels back to
// the app through the nessotalk:// deep link.
//
// This route requires a real session cookie, so it can only be called by
// someone who has actually signed in. The app never sees the session; it only
// ever receives the short-lived code, and even that is useless without the
// verifier it kept to itself.
export const dynamic = "force-dynamic";

export async function POST(req: Request) {
  const {
    data: { user },
  } = await supabaseServer().auth.getUser();
  if (!user) return NextResponse.json({ error: "signin_required" }, { status: 401 });

  let deviceCode = "";
  try {
    deviceCode = String((await req.json()).device_code ?? "");
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }
  if (!deviceCode) return NextResponse.json({ error: "bad_request" }, { status: 400 });

  const db = adminDb();
  const { data: row } = await db
    .from("device_auth")
    .select("device_code, claimed, created_at")
    .eq("device_code", deviceCode)
    .maybeSingle();
  if (!row || row.claimed) {
    return NextResponse.json({ error: "expired" }, { status: 400 });
  }
  if (Date.now() - Date.parse(row.created_at) > 10 * 60 * 1000) {
    return NextResponse.json({ error: "expired" }, { status: 400 });
  }

  const authCode = randomBytes(24).toString("base64url");
  const { error } = await db
    .from("device_auth")
    .update({ user_id: user.id, auth_code: authCode })
    .eq("device_code", deviceCode)
    .eq("claimed", false);
  if (error) return NextResponse.json({ error: "bind_failed" }, { status: 500 });

  // The app is listening for this. The code is single use and dies in ten
  // minutes, and it carries no licence key of its own.
  return NextResponse.json({ redirect: `nessotalk://auth?code=${authCode}` });
}
