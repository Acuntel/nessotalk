import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Server-side AI rewrite proxy. This is the part that CANNOT be stolen with the
// app: Summarize / Professional / command-mode edits run here, gated on a live
// license, using our API key. A cracked copy gets local transcription only,
// which is open-source whisper anyway. The differentiated features stop working
// the moment someone stops paying, and no amount of patching their binary
// changes that, because the capability was never on their machine.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const INSTRUCTIONS: Record<string, string> = {
  summarize: `Rewrite this dictated transcript into a clear, well-structured document for an AI assistant. Rules:
- Keep EVERY specific detail: names, numbers, prices, file paths, product names, constraints, sequences, conditions, examples.
- EXPAND, never compress: unpack each spoken thought into its complete meaning. Output should be AS LONG OR LONGER than the transcript.
- Keep the speaker's reasoning and the WHY behind each decision.
- Resolve self-corrections to the FINAL decision only.
- Organize with headers and numbered or dashed lists following the speaker's own structure.
- Do NOT invent requirements, do NOT answer the content, do NOT drop anything.
Output ONLY the rewritten text, no preamble.`,
  professional: `Rewrite this dictated gist into polished, natural prose ready to send as a text message or email. Rules:
- Fix all grammar, spelling, punctuation, sentence structure; complete half-finished sentences into what the speaker clearly meant.
- Remove filler, false starts, rambling; resolve self-corrections to the FINAL decision.
- Keep every fact, name, number, date, amount, and commitment exactly as spoken. Never invent content.
- Tone: clear, warm, professional. Natural human writing.
- Never use em dashes or en dashes. Use a period, comma, or colon instead.
- No greeting or sign-off unless dictated. No subject line. No commentary.
Output ONLY the rewritten message.`,
  command: `You are a text editor. You will receive SELECTED TEXT and a spoken INSTRUCTION describing how to change it. Apply the instruction. Rules:
- Output ONLY the edited text, ready to replace the selection. No preamble, no commentary, no surrounding quotes.
- Keep everything the instruction does not ask to change.
- Never use em dashes or en dashes. Use a period, comma, or colon instead.
- If the instruction is not an edit request, output the original text unchanged.`,
};

export async function POST(req: Request) {
  let key = "";
  let mode = "";
  let text = "";
  try {
    const body = await req.json();
    key = String(body.key ?? "").trim();
    mode = String(body.mode ?? "").trim();
    text = String(body.text ?? "");
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }

  const instruction = INSTRUCTIONS[mode];
  if (!instruction) return NextResponse.json({ error: "bad_mode" }, { status: 400 });
  if (!/^[0-9a-f-]{36}$/i.test(key)) return NextResponse.json({ error: "bad_key" }, { status: 401 });
  if (!text.trim()) return NextResponse.json({ error: "empty" }, { status: 400 });
  if (text.length > 60_000) return NextResponse.json({ error: "too_long" }, { status: 413 });

  const db = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
  const { data: p } = await db
    .from("profiles")
    .select("plan, trial_ends_at, revoked")
    .eq("license_key", key)
    .maybeSingle();

  if (!p || p.revoked) return NextResponse.json({ error: "inactive" }, { status: 402 });
  const trialLive = p.trial_ends_at ? new Date(p.trial_ends_at).getTime() > Date.now() : false;
  if (p.plan === "trial" && !trialLive) {
    return NextResponse.json({ error: "expired" }, { status: 402 });
  }

  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) return NextResponse.json({ error: "proxy_unconfigured" }, { status: 503 });

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-sonnet-5",
      max_tokens: 16000,
      messages: [{ role: "user", content: instruction + "\n\nTranscript:\n" + text }],
    }),
  });
  if (!res.ok) return NextResponse.json({ error: "upstream" }, { status: 502 });
  const data = await res.json();
  const out = data?.content?.[0]?.text;
  if (typeof out !== "string" || !out.trim()) {
    return NextResponse.json({ error: "empty_upstream" }, { status: 502 });
  }
  return NextResponse.json({ text: out });
}
