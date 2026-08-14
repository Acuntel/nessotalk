import { NextResponse } from "next/server";
import AdmZip from "adm-zip";
import path from "path";
import { accessFor } from "@/lib/access";
import { adminDb } from "@/lib/db";

// In-app updates. `ptt update` sends its license key as a header and gets the
// current build back, personalized the same way the first download was. An
// inactive subscription gets 402, so a lapsed customer stops receiving updates
// as well as losing the AI features.
export const dynamic = "force-dynamic";

// Windows is withheld here too. That zip is readable C# source under an MIT
// licence, so handing it to a customer hands over the right to resell NessoTalk.
const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
};

export async function GET(req: Request) {
  const platform = new URL(req.url).searchParams.get("platform") ?? "";
  const file = FILES[platform];
  if (!file) return NextResponse.json({ error: "bad_platform" }, { status: 400 });

  const key = (req.headers.get("x-license-key") ?? "").trim();
  if (!/^[0-9a-f-]{36}$/i.test(key)) {
    return NextResponse.json({ error: "bad_key" }, { status: 401 });
  }

  const db = adminDb();
  const { data: p } = await db
    .from("profiles")
    .select("plan, trial_ends_at, revoked")
    .eq("license_key", key)
    .maybeSingle();

  // Same rule as /api/download. These two used to disagree: download served a
  // live trial and update refused it, so trial customers were frozen on
  // whatever build they first installed.
  const verdict = accessFor(p);
  if (!verdict.ok) {
    return NextResponse.json({ error: verdict.reason }, { status: 402 });
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
