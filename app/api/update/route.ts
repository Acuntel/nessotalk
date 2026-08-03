import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import AdmZip from "adm-zip";
import path from "path";

// In-app updates. `ptt update` sends its license key as a header and gets the
// current build back, personalized the same way the first download was. An
// inactive subscription gets 402, so a lapsed customer stops receiving updates
// as well as losing the AI features.
export const dynamic = "force-dynamic";

const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
  windows: "nessotalk-windows-beta.zip",
};

export async function GET(req: Request) {
  const platform = new URL(req.url).searchParams.get("platform") ?? "";
  const file = FILES[platform];
  if (!file) return NextResponse.json({ error: "bad_platform" }, { status: 400 });

  const key = (req.headers.get("x-license-key") ?? "").trim();
  if (!/^[0-9a-f-]{36}$/i.test(key)) {
    return NextResponse.json({ error: "bad_key" }, { status: 401 });
  }

  const db = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
  const { data: p } = await db
    .from("profiles")
    .select("plan, revoked")
    .eq("license_key", key)
    .maybeSingle();

  if (!p || p.revoked || p.plan === "trial") {
    return NextResponse.json({ error: "inactive" }, { status: 402 });
  }

  const zip = new AdmZip(path.join(process.cwd(), "assets", "downloads", file));
  const root = platform === "mac" ? "nessotalk-mac" : "nessotalk-windows";
  zip.addFile(`${root}/LICENSE_KEY`, Buffer.from(key + "\n"));

  return new NextResponse(new Uint8Array(zip.toBuffer()), {
    status: 200,
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${file}"`,
      "cache-control": "no-store",
    },
  });
}
