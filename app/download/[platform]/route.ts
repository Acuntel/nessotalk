import { NextResponse } from "next/server";
import fs from "fs";
import path from "path";

// Public, Wispr-style downloads: click the button, get the app. No account
// wall. The app is the free part: it will not record without a live license,
// and transcription itself happens on our hosted engine, so a passed-around
// zip carries nothing worth having. Selling happens at the license, not the
// download.
export const dynamic = "force-dynamic";

const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
  windows: "nessotalk-windows-beta.zip",
};

export async function GET(
  _req: Request,
  { params }: { params: { platform: string } }
) {
  const file = FILES[params.platform];
  if (!file) return NextResponse.json({ error: "bad_platform" }, { status: 400 });

  const buf = fs.readFileSync(path.join(process.cwd(), "assets", "downloads", file));
  return new NextResponse(new Uint8Array(buf), {
    status: 200,
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${file}"`,
      "cache-control": "no-store",
    },
  });
}
