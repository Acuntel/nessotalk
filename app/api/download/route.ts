import { NextResponse } from "next/server";
import { supabaseServer } from "@/lib/supabase/server";
import AdmZip from "adm-zip";
import path from "path";
import { accessFor } from "@/lib/access";

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

// Windows is withheld here for the same reason it is withheld from the public
// route: that zip is readable C# source under an MIT licence, so shipping it to
// a paying customer gives away the right to resell the product.
const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
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
  // A live trial gets the real build. "Fourteen days free" has to mean a
  // working app, or the promise on the pricing card is not true.
  //
  // Access still ends on its own: an expired trial 402s here, the license
  // check refuses, and the engine stops transcribing. Shared with /api/update
  // so the two can never drift apart again.
  if (!profile) {
    return NextResponse.json({ error: "unknown" }, { status: 402 });
  }
  const verdict = accessFor(profile);
  if (!verdict.ok) {
    const error = verdict.reason === "expired" ? "subscribe_required" : verdict.reason;
    return NextResponse.json({ error }, { status: 402 });
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
