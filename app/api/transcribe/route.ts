import { NextResponse } from "next/server";

// Stable public front for the hosted engine. Clients talk to nesso.tech and
// never learn where the engine actually runs, so the backend can move hosts
// (Railway CPU today, GPU box tomorrow) with zero client changes.
//
// This is a dumb pipe on purpose: the engine gate owns license validation,
// forwarding the client's own machine id and platform for seat binding. One
// validation, one owner. Note Vercel bodies cap at ~4.5 MB, which fits the
// chunked path (a 60s chunk of 16 kHz mono s16 is ~1.9 MB); anything bigger
// should hit the engine directly at the URL /api/license hands out.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

export async function POST(req: Request) {
  const engine = process.env.ENGINE_URL;
  if (!engine) {
    return NextResponse.json({ error: "engine_unconfigured" }, { status: 503 });
  }

  let form: FormData;
  try {
    form = await req.formData();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const res = await fetch(`${engine.replace(/\/$/, "")}/transcribe`, {
    method: "POST",
    headers: { "x-license-key": req.headers.get("x-license-key") ?? "" },
    body: form,
  });

  const body = await res.text();
  return new NextResponse(body, {
    status: res.status,
    headers: { "content-type": "application/json" },
  });
}
