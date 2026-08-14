import { NextResponse } from "next/server";
import fs from "fs";
import path from "path";

// Public, Wispr-style downloads: click the button, get the app. No account
// wall. The app is the free part: it will not record without a live license,
// and transcription itself happens on our hosted engine, so a passed-around
// zip carries nothing worth having. Selling happens at the license, not the
// download.
export const dynamic = "force-dynamic";

// Windows is deliberately absent. That zip ships the full C# source with an MIT
// LICENSE in it, which hands every person who downloads it the right to modify,
// redistribute, and sell NessoTalk, and the license check there is a handful of
// deletable lines. It comes back when there is a compiled binary from a Windows
// runner, a proprietary licence, and one real run on real Windows hardware.
const FILES: Record<string, string> = {
  mac: "nessotalk-mac-beta.zip",
};

export async function GET(
  _req: Request,
  { params }: { params: { platform: string } }
) {
  if (params.platform === "windows") {
    return NextResponse.json(
      { error: "windows_not_released", message: "The Windows app is not out yet. NessoTalk for Mac is available now." },
      { status: 404 }
    );
  }
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
