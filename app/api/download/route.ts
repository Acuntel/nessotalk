import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";
import { createCipheriv, pbkdf2Sync, randomBytes } from "crypto";
import { readFile } from "fs/promises";
import path from "path";

// Auth-gated, per-license encrypted download.
//
// The payload is encrypted with a key derived from the caller's own license
// key, in the same format `openssl enc -aes-256-cbc -pbkdf2` reads. A copy
// passed to a friend is inert without that key, and handing over the key hands
// over a revocable, seat-capped license that is also the only way to reach the
// AI rewrite features. Being straight about the limit: this raises the cost of
// casual sharing, it does not make the bits uncopyable. Nothing does.
export const dynamic = "force-dynamic";

const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
  windows: "nessotalk-windows-beta.zip",
};

export async function GET(req: Request) {
  const platform = new URL(req.url).searchParams.get("platform") ?? "";
  const file = FILES[platform];
  if (!file) return NextResponse.json({ error: "bad_platform" }, { status: 400 });

  const supabase = supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return NextResponse.json({ error: "sign_in_required" }, { status: 401 });

  const { data: profile } = await supabase
    .from("profiles")
    .select("license_key, plan, trial_ends_at, revoked")
    .eq("id", user.id)
    .single();
  if (!profile || profile.revoked) {
    return NextResponse.json({ error: "inactive" }, { status: 402 });
  }
  const trialLive = profile.trial_ends_at
    ? new Date(profile.trial_ends_at).getTime() > Date.now()
    : false;
  if (profile.plan === "trial" && !trialLive) {
    return NextResponse.json({ error: "expired" }, { status: 402 });
  }

  const plain = await readFile(path.join(process.cwd(), "public", "downloads", file));

  // OpenSSL-compatible: "Salted__" + 8-byte salt + AES-256-CBC, key/iv from
  // PBKDF2-SHA256(licenseKey, salt, 10000).
  const salt = randomBytes(8);
  const material = pbkdf2Sync(profile.license_key, salt, 10000, 48, "sha256");
  const cipher = createCipheriv("aes-256-cbc", material.subarray(0, 32), material.subarray(32, 48));
  const body = Buffer.concat([
    Buffer.from("Salted__"),
    salt,
    cipher.update(plain),
    cipher.final(),
  ]);

  return new NextResponse(body, {
    status: 200,
    headers: {
      "content-type": "application/octet-stream",
      "content-disposition": `attachment; filename="${file}.enc"`,
      "cache-control": "no-store",
    },
  });
}
