# NessoTalk MASTERPROMPT: remaining work after the 08-14 fix pass

**Status when this was written:** v8.24 is live. The four launch blockers from the audit are
fixed and deployed, plus a fifth found while verifying them. The engine went from 16.7s to
3.0s on a short dictation. Two things still stand between NessoTalk and a paying stranger,
and both start with a decision only Brady can make.

**Read this before executing anything. Nothing in here has been done.**

---

## 0. Standing doctrine, not up for debate

1. **Nobody gets the model.** Transcription happens on our hosted engine, gated per request,
   revocable. No decode model on a customer disk. Confirmed by Brady 08-14: *"Make sure people
   never download it, they're just given access through the model that we created. I'm allowed
   to access it, give it to people, and take it away from them."*
2. **Revocability is a hosting property, not a model property.** Any model swap must keep the
   licence gate in front of the decoder. If a proposal moves decoding onto the customer's
   machine, it is out of scope no matter how fast it is.
3. **No claim ships that we cannot point at a measurement for.** Every number on the site must
   have a dated measurement next to it in the code.
4. **No em dashes or en dashes in customer-facing copy. Full sentences, not fragments.**

---

## 1. Traps that have already cost time. Read before touching anything.

| Trap | What happens | What to do |
|---|---|---|
| **Railway has no GitHub webhook** | Pushing to main deploys the SITE but never the ENGINE. Silent. | `cd ~/dev/nessotalk/engine && railway up --detach`. Always. |
| **Next.js caches `fetch`** | supabase-js reads through the global fetch, so an access check can be served from a stale row. `force-dynamic` does NOT cover it. This let a revoked customer keep downloading builds. | Any Supabase read behind an access decision goes through `lib/db.ts adminDb()` or the patched `lib/supabase/server.ts`. Never build a raw client inline. |
| **audio_ctx below ~448 destroys the transcript** | The decoder collapses into a repetition loop. The widely published formula computes 348, which is inside the broken zone. | Floor stays 512. If you change it, sweep against held-out audio first. `AUDIO_CTX=0` disables without a redeploy. |
| **Version pair must move together** | `APP_VERSION` in the daemon and `LATEST_VERSION` in `app/api/license/route.ts`. If they drift, customers either never get offered an update or get nagged forever. | Bump both in the same commit. Verify live via `/api/license`. |
| **`NSHomeDirectory()` ignores `$HOME`** | You cannot fake a customer home directory to test first-run behaviour. | Edit `~/.dictation/config` with a `trap`-based restore instead. |
| **zsh does not word-split unquoted `$VAR`** | CLI flag strings pass as one argument and the command fails silently with empty output. | Use `${=VAR}`. |
| **Zips need `ditto -c -k --norsrc --keepParent`** | Plain `zip` injects AppleDouble junk. | Rebuild both zips from `apps/*` after any client change. |
| **Never `git checkout` a compiled `.app`** | Git text-normalises the Mach-O and produces a segfault. | `.gitattributes` already marks them binary. Do not remove those lines. |
| **`Config.load()` may reference only literals** | Referencing another file-scope global segfaults the daemon at launch, because Swift initialises top-level globals in order. This took the product down for 20 minutes once. | Validate inline. Never reference a global declared later. |

---

## 2. PHASE A: the two switches that block a paying customer

Neither of these is optional, and neither can be done without Brady. Everything in Phase B and
beyond is worth less than these two until they are done.

### A1. Stripe webhook. Without this, paying grants nothing.

**Current state:** `/api/stripe/webhook` returns `503 webhook_unconfigured`. The handler code
is written and correct. `STRIPE_WEBHOOK_SECRET` is absent from Vercel production. A customer
who pays is charged and then disarmed when their trial lapses, and because
`stripe_customer_id` stays null, no later Stripe event can ever find their row again.

**Brady does:**
1. Stripe Dashboard → Developers → Webhooks → Add endpoint.
2. URL: `https://nesso.tech/api/stripe/webhook`
3. Events: `checkout.session.completed`, `customer.subscription.updated`,
   `customer.subscription.deleted`, `invoice.paid`, `invoice.payment_failed`
4. Copy the signing secret (starts `whsec_`) and hand it over, or run it himself:
   `cd ~/dev/nessotalk && npx vercel env add STRIPE_WEBHOOK_SECRET production`

**Then I do:**
1. Redeploy: `npx vercel --prod --yes`
2. Add a `processed_events` table keyed on Stripe's `event.id`, written in the same
   transaction as the plan grant, so a retry cannot double-apply.
3. Verify the signature is checked against the RAW body, not the parsed JSON.
4. Replay any events Stripe has been retrying. **Time-sensitive: Stripe gives up after about
   72 hours and disables the endpoint.**
5. Live test with a real Stripe test-mode checkout, end to end, then delete the test customer.

**Definition of done:** a test checkout flips `profiles.plan` to `pro` with no human touching
`/admin`, a duplicate replay of the same event does not double-apply, and a simulated
`invoice.payment_failed` drops the account back to `trial`.

**Rollback:** remove the env var. The route returns 503 again and plan flips go back to manual
via `/admin`, which is exactly today's behaviour. Zero risk.

---

### A2. Notarization. Without this, the first thing a customer sees is "Move to Trash".

**Current state:** the app is signed with an *Apple Development* certificate, which is not a
distribution certificate, and it is not notarized. `spctl` rejects it. I proved that a
quarantined copy of the shipped zip hangs forever and produces nothing. `install.sh` now
clears the quarantine flag from the app it installs, but **`Install NessoTalk.command` itself
is still blocked on download**, and since macOS 15 the right-click-to-Open workaround is gone.

**Brady does:** buy the Apple Developer Program membership, $99 a year, and create a
**Developer ID Application** certificate. Confirm the team id (currently PY94U6N48R).

**Then I do:**
1. Re-sign the bundle with the Developer ID cert, hardened runtime enabled.
2. Add `com.apple.security.cs.disable-library-validation` to the entitlements. **Required**,
   because the daemon shells out to whisper-cli and ffmpeg.
3. Submit with `notarytool`, wait for the automated scan (typically about 15 minutes, it is a
   scan not a review queue), then `stapler staple` the ticket.
4. Rebuild both zips, re-verify with `spctl -a -vvv -t exec` and `xcrun stapler validate`.
5. **Re-run the quarantine A/B test I used to find this**: apply
   `com.apple.quarantine` to a fresh extraction and confirm the binary now runs instead of
   hanging. That test is the definition of done, not the notarytool success message.
6. Update `components/Walkthrough.tsx` to delete the "System Settings → Open Anyway"
   instructions, which become wrong once notarized.

**Definition of done:** `spctl -a -t exec` returns accepted, `stapler validate` passes, and a
quarantined copy launches without a dialog.

**Risk:** re-signing with a new identity changes the code signature, which **will reset the
microphone and accessibility grants on Brady's own machine once**. Expect to re-grant both.
This is the same one-time cost as the v5 adhoc-to-AppleDev switch. It does not recur.

---

## 3. PHASE B: Parakeet. Measure first, decide second.

Sam suggested Parakeet. My read after research: **he is right that it is a better model, it
does not change revocability at all, and it is worth doing as a SECOND engine rather than a
replacement.** But the whole decision rests on one number nobody has published for our
hardware, so B1 is a measurement with a hard go/no-go gate and no production change.

### What Parakeet would buy

- CPU throughput. Published CPU figure for `parakeet-tdt-0.6b-v3` q8_0 is **34x realtime** on
  a 20-core x86 host at 8 threads. Our whisper large-v3-turbo q5_0 measures **~1.75x** on
  Railway. Even derated hard for shared vCPUs that is a large gain.
- **The 110M variant is the sleeper**: `parakeet-tdt_ctc-110m` at **91.5x realtime and 563 MB
  RSS**, with a better LibriSpeech WER than the 0.6B CTC model. English only. At that memory
  footprint we can run several replicas in the RAM we already pay for, which is what actually
  fixes concurrency.
- Better accuracy overall (6.32% vs 7.44% average WER) and **native punctuation and
  capitalization**, which retires some hand-written Swift.
- **It structurally cannot hallucinate on silence.** A frame-synchronous transducer emits
  nothing when there is no speech. This is the exact class of bug that produced the "Jeremy
  Hayes" incident, where a name Brady never said appeared in a transcript.
- No 30-second encoder window, which is what currently drops spans from whole-file decodes.
  My test clip loses the phrase "and it absolutely cannot require anyone", inverting a
  constraint. That bug disappears.

### What it would cost

- **Language coverage drops from 99 to 25.** Worse, Parakeet has no language input at all and
  on ambiguous non-English speech it **silently translates into English instead of
  transcribing**. One team measured a 31% failure rate on a 40-minute French recording. Our
  pricing page says "100+ languages" and I verified Spanish works correctly today.
- **No decode-time vocabulary biasing.** We currently send whisper a prompt listing Nesso,
  StolenMule, KARL, Meemoo, Sabify and others. No runtime we would deploy has an equivalent.
  The `fuzzyLearnedPass` regex corrections survive untouched, because they run after decoding.
- `parakeet.cpp` is about ten weeks old, v0.5.0, pre-1.0. Pin a version deliberately.
- Weights are NVIDIA's under CC-BY-4.0. Commercially fine for a closed-source paid service,
  but it needs an attribution line, and it does not make the model "ours" any more than
  whisper does.

---

### B1. The spike. No production change. This is the whole decision.

**Cost:** roughly an hour, plus a few dollars of Railway compute. **Nothing customer-facing
is touched.**

1. Create a **throwaway** Railway service in the existing `nessotalk-engine` project. Do not
   touch the live service.
2. Run `ghcr.io/mudler/parakeet.cpp-server` pinned to a specific tag, not `latest`.
3. Load two models and benchmark both: `tdt-0.6b-v3-q8_0.gguf` and `tdt_ctc-110m-q8_0.gguf`.
4. Replay **the exact clips already used for every measurement in this project**: the 4.4s
   invoice clip, the 4.7s meeting clip, and the 35.5s deployment-pipeline clip. Plus the
   Spanish and French clips, specifically to observe the translation failure mode.
5. Measure, for each model: single-clip wall clock, four-concurrent wall clock, peak RSS,
   cold start, and container image size.
6. Diff every transcript against the current whisper output word by word. **Specifically check
   whether the 35.5s clip retains "and it absolutely cannot require anyone", which whisper
   currently drops.**

**GO if all of these hold:**
- Short clip round trip is **at or under 1.5s**, against 3.0s today.
- The 35.5s clip is **at or under 8s**, against 20.3s today.
- Four concurrent short clips finish in **under 6s of wall clock**, against 13s today.
- English transcripts are equal or better on the money, time, and proper-noun cases.
- Peak RSS leaves room for at least three replicas in the current container.

**NO-GO and we stop, keeping whisper, if any of these appear:**
- Short-clip latency does not beat 2.5s, meaning fixed overhead dominates and the model is
  not the bottleneck.
- Any English transcript is worse on numbers, times, or names.
- The Spanish clip comes back translated into English rather than transcribed.
- RSS makes replicas impossible in the current container size.

**Deliverable:** a written before-and-after table, and a recommendation. **I stop here and
report. No production change without Brady reading the numbers.**

---

### B2. Only if B1 is a GO: Parakeet as a second engine, never a replacement

**Design: route by language, keep whisper.**

- English, and optionally the other 24 European languages, go to Parakeet.
- Everything else stays on whisper, which preserves the "100+ languages" claim honestly.
- The router lives in `gate.py`, so it is a server-side decision and **no client update is
  needed for any customer**.

**Steps:**
1. Add a second decoder container alongside the existing whisper-server. Both stay on
   localhost. `gate.py` remains the only public surface and the only licence gate.
2. Route on the `language` field the client already sends. Default English to Parakeet.
3. **Fix concurrency with process replicas, not batching.** The encoder is about 98% of CPU
   time, so batching helps far less than the headline suggests. N replicas behind the gate is
   the simple thing that works.
4. **Do not use the default ONNX int8 build.** It has a documented accuracy cliff past roughly
   20 to 30 seconds, measured at 24.8% WER against 7.8% for fp32. GGUF via parakeet.cpp does
   not have this. If ONNX is ever used, it must be the SmoothQuant build.
5. Add the CC-BY-4.0 attribution line to a public acknowledgements page linked from the footer.
6. Keep `ENGINE=whisper` as an env-var kill switch that routes everything back to whisper.

**Definition of done:** the full audit gauntlet re-run green, the grant/revoke/restore cycle
still flips within 60 seconds, Spanish still transcribes rather than translates, and the
before-and-after numbers published in the report artifact.

**Rollback:** flip the env var. One redeploy, no client change.

---

## 4. PHASE C: reliability, after A and B

Ordered by how likely each is to cost a customer.

1. **Error monitoring.** There is none anywhere. Today we find out about failures when someone
   emails. Sentry in the Next.js app and in the daemon, with **client-side rate limiting
   configured first**, because a launchd crash loop can drain a free tier in minutes.
2. **Seat unbind.** There is no way to move a licence to a new Mac, in `/admin` or self-serve.
   The licensing industry reports this as the single most common support ticket. Add an unbind
   button to `/admin` first, self-serve later.
3. **The whisper long-form dropout**, if Parakeet is a NO-GO. Lower `CHUNK_SECONDS` so chunking
   engages before the 30-second boundary, and run the chunk path for every recording rather
   than only long ones. A tool that silently deletes the word "cannot" from a constraint is
   worse than a slow one.
4. **Trial abuse.** Trials are unlimited per email address with no verification. The cheapest
   real fix is a usage cap rather than identity checks, which is what every competitor does.
   A weekly word cap also creates a free tier, which is a growth feature rather than a chore.
5. **Self-serve cancel.** The site now honestly says to email, because that is the truth. A
   Stripe billing portal link is roughly an hour once A1 is done.

---

## 5. Explicitly NOT doing, and why

- **Moving decoding onto the customer's Mac**, including FluidAudio and Parakeet on the Neural
  Engine, even though it is by far the fastest option. It breaks the doctrine in section 0.
- **Buying a GPU host.** At current volume it is not the bottleneck, and research shows GPUs
  buy concurrency far more than single-request latency. Revisit only when replicas stop coping.
- **Confidence-score error highlighting.** Two independent studies 24 years apart found it does
  not improve accuracy and that users dislike it. Spend that effort on custom vocabulary.
- **Releasing Windows.** It ships readable C# under an MIT licence, has never been executed on
  real Windows hardware, and is currently withheld from all three download routes. It returns
  only with a compiled binary from a Windows CI runner, a proprietary licence, and a rewritten
  README.
- **Switching decode flags to greedy.** Measured: it saves 1843ms to 1649ms on its own, which
  is not worth the quality risk. The engine flags deliberately mirror the desktop's proven args.

---

## 6. Suggested order

| | Work | Who | Blocking? |
|---|---|---|---|
| 1 | Stripe webhook | Brady, then me | **Yes.** Every sale converts at zero until done. |
| 2 | Notarization | Brady, then me | **Yes** for cold traffic. |
| 3 | Parakeet spike (B1) | Me | No. Pure measurement, no production change. |
| 4 | Parakeet routing (B2) | Me, only on a GO | No |
| 5 | Sentry, seat unbind, trial cap | Me | No |

**If Brady wants only one thing done next: the Stripe webhook.** Everything else improves a
product that currently cannot take money.
