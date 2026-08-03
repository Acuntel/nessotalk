import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";
import AdmZip from "adm-zip";
import path from "path";

// Auth-gated, personalized download.
//
// The build is assembled per request with the caller's own license key written
// into it, so the customer never types a key or runs an unlock command: they
// download, run the installer, and it works. Every copy is also stamped with
// the key it was issued to, so a leaked copy identifies its source.
//
// The zips live outside public/ on purpose. Anything under public/ is served
// to anyone with the URL, which would defeat this entire route.
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

  const zip = new AdmZip(path.join(process.cwd(), "assets", "downloads", file));
  const root = platform === "mac" ? "nessotalk-mac" : "nessotalk-windows";
  zip.addFile(`${root}/LICENSE_KEY`, Buffer.from(profile.license_key + "\n"));

  return new NextResponse(new Uint8Array(zip.toBuffer()), {
    status: 200,
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${file}"`,
      "cache-control": "no-store",
    },
  });
}
