import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

// Server-side AI rewrite proxy. This is the part that CANNOT be stolen with the
// app: Summarize / Professional / Agent / Expand / command-mode edits run here,
// gated on a live license, using our API key. A cracked copy gets local
// transcription only, which is open-source whisper anyway. The differentiated
// features stop working the moment someone stops paying, and no amount of
// patching their binary changes that, because the capability was never on their
// machine.
//
// It also means the model, effort, and token budget for every customer are
// decided here. One edit changes unit economics fleet-wide with no client
// update. Clients send only {key, mode, text}.
export const dynamic = "force-dynamic";
export const maxDuration = 60;

type Mode = {
  instruction: string;
  model: string;
  maxTokens: number;
  // Haiku 4.5 REJECTS output_config.effort. Only set this on Sonnet-tier models.
  effort?: "low" | "medium" | "high";
};

// Sonnet 5 runs ADAPTIVE THINKING when `thinking` is omitted, and thinking bills
// as ordinary output tokens. Effort is the documented primary cost control, so
// every Sonnet mode below sets it explicitly rather than defaulting to high.
const SONNET = "claude-sonnet-5";
const HAIKU = "claude-haiku-4-5";

const NO_DASHES =
  "Never use em dashes or en dashes. Use a period, comma, or colon instead.";
const STRIP_FILLER =
  "Remove filler, false starts, and thinking-out-loud. Resolve self-corrections to the FINAL decision only.";

const MODES: Record<string, Mode> = {
  summarize: {
    model: SONNET,
    effort: "medium",
    maxTokens: 16000,
    instruction: `Rewrite this dictated transcript into a clear, well-structured document for an AI assistant. Rules:
- Keep EVERY specific detail: names, numbers, prices, file paths, product names, constraints, sequences, conditions, examples.
- EXPAND, never compress: unpack each spoken thought into its complete meaning. Output should be AS LONG OR LONGER than the transcript.
- Keep the speaker's reasoning and the WHY behind each decision.
- ${STRIP_FILLER}
- Organize with headers and numbered or dashed lists following the speaker's own structure.
- Do NOT invent requirements, do NOT answer the content, do NOT drop anything.
Output ONLY the rewritten text, no preamble.`,
  },

  professional: {
    model: HAIKU,
    maxTokens: 2000,
    instruction: `Rewrite this dictated gist into polished, natural prose ready to send as a text message or email. Rules:
- Fix all grammar, spelling, punctuation, sentence structure; complete half-finished sentences into what the speaker clearly meant.
- ${STRIP_FILLER}
- Keep every fact, name, number, date, amount, and commitment exactly as spoken. Never invent content.
- Tone: clear, warm, professional. Natural human writing.
- ${NO_DASHES}
- No greeting or sign-off unless dictated. No subject line. No commentary.
Output ONLY the rewritten message.`,
  },

  command: {
    model: HAIKU,
    maxTokens: 4000,
    instruction: `You are a text editor. You will receive SELECTED TEXT and a spoken INSTRUCTION describing how to change it. Apply the instruction. Rules:
- Output ONLY the edited text, ready to replace the selection. No preamble, no commentary, no surrounding quotes.
- Keep everything the instruction does not ask to change.
- ${NO_DASHES}
- If the instruction is not an edit request, output the original text unchanged.`,
  },

  // AGENT: a spoken ramble becomes the brief the speaker would have written if
  // they had time. Every rule below is load-bearing, from measured findings:
  // full spec vs underspecified is worth 16 points of task success and is 2.1x
  // cheaper than the agent asking clarifying questions afterward; conditional
  // requirements are guessed correctly only ~23% of the time while formatting
  // is guessed right ~71%, so conditionals are where the words belong;
  // instruction-following degrades from 98.7% at one requirement to 85% at
  // nineteen, so padding actively hurts; and fixed subtask lists raise retry
  // cost ~80% over not decomposing at all, because one failure re-runs
  // everything downstream.
  agent: {
    model: SONNET,
    effort: "high",
    maxTokens: 16000,
    instruction: `Turn this spoken description into a brief for an AI coding agent. The speaker was thinking out loud. Produce the specification they would have written if they had time.

Use exactly these sections, and omit any section with no real content rather than filling it:

**Goal**
One sentence naming the outcome, not the steps.

**Constraints**
Every condition, edge case, and "only if" rule the speaker stated or clearly implied, plus anything that must not change. This section matters most. Agents guess conditional logic wrong most of the time, so make each one explicit even when it feels obvious.
Always end this section with these two lines verbatim, because an agent stops when the work looks done and without a scope cap the most complete-looking answer wins, which means more code than was asked for:
- No new dependency or package without asking first. Prefer what is already in the project.
- No abstractions, config, or flexibility beyond what is asked. Match the closest existing pattern rather than inventing one.

**Done when**
Concrete checkable criteria. Strongly prefer a command the agent can actually run over a description of correctness: "run the existing test suite and it passes" beats "make sure nothing breaks". If the speaker described behavior, turn it into an observable check, for example "an expired token returns 401".

**Context**
Files, paths, error text, stack, and existing patterns the speaker referenced or was looking at.
Quote the handful of lines that actually matter inline. Do not write "see file X" for anything load-bearing. Agents frequently do not open files they are merely pointed at, so a pointer is close to no context at all.

Rules:
- Do NOT write a numbered plan or a list of subtasks. State the goal and constraints and let the agent sequence its own work. A fixed step list forces every later step to re-run when one fails.
- Do NOT add any requirement the speaker did not state or clearly imply. An invented constraint is worse than a missing one.
- Do NOT pad. Every extra requirement measurably degrades instruction-following. If something is obvious from context, leave it out.
- Do NOT tell the agent to double-check, verify, or review its work. Current models already do this, and asking makes them over-verify and waste tokens.
- Include one line telling the agent to work directly rather than announce each step. Narrating "Let me check, let me verify, let me try that again" across tool calls burns context without adding signal, and it is a separate problem from a padded final answer.
- ${STRIP_FILLER}
- Plain declarative language. No all-caps urgency words like CRITICAL or MUST, which make current models overreact and overbuild.
- ${NO_DASHES}
Output ONLY the brief.`,
  },

  // EXPAND: one terse sentence becomes a detailed request. The failure mode to
  // design against is fabrication, so the prompt forces open questions instead
  // of invented detail, and blocks padding on dimensions models already guess
  // correctly.
  expand: {
    model: SONNET,
    effort: "medium",
    maxTokens: 8000,
    instruction: `The speaker said something short. Expand it into a complete, detailed request an AI can act on without guessing.

Expand along the dimensions where AI most often guesses wrong:
- Conditional logic and edge cases: what should happen if the input is empty, missing, malformed, or unexpected.
- Constraints, and anything that must not change.
- What "done" looks like, concretely.
- Context the speaker assumed but did not say out loud.

Do NOT expand:
- Formatting or style preferences, unless the speaker raised them.
- Anything already unambiguous.
- The same point restated in different words purely to add length.

Rules:
- Ground every added sentence in what the speaker actually said or what follows necessarily from it. Never invent a requirement, number, name, path, or constraint. Fabricated detail is worse than the original short version.
- If a detail genuinely cannot be inferred, do not guess. Put it as a short open question on its own line at the end under "Open questions".
- Keep every fact, name, number, path, and amount exactly as spoken.
- ${STRIP_FILLER}
- Aim for substantially more detail than the input, then stop the moment you would be padding.
- ${NO_DASHES}
Output ONLY the expanded request.`,
  },
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

  const cfg = MODES[mode];
  if (!cfg) return NextResponse.json({ error: "bad_mode" }, { status: 400 });
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

  const payload: Record<string, unknown> = {
    model: cfg.model,
    max_tokens: cfg.maxTokens,
    messages: [{ role: "user", content: cfg.instruction + "\n\nTranscript:\n" + text }],
  };
  // Only Sonnet-tier models accept output_config.effort; Haiku 4.5 errors on it.
  if (cfg.effort) payload.output_config = { effort: cfg.effort };

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
      "content-type": "application/json",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) return NextResponse.json({ error: "upstream" }, { status: 502 });
  const data = await res.json();
  if (data?.stop_reason === "refusal") {
    return NextResponse.json({ error: "refused" }, { status: 502 });
  }
  const out = data?.content?.find((b: { type?: string }) => b?.type === "text")?.text;
  if (typeof out !== "string" || !out.trim()) {
    return NextResponse.json({ error: "empty_upstream" }, { status: 502 });
  }
  return NextResponse.json({ text: out });
}
