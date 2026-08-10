# Windows parity tasks (target: Mac v8.1 behavior)

The Mac daemon (`apps/mac/ptt-dictate.swift`) is the reference implementation.
Work these in order; each task lists the exact behavior contract.

## 1. Recording pill UI (Wispr-style HUD)
- Borderless, always-on-top, NON-ACTIVATING pill at bottom-center of the active
  screen (WPF: `ShowActivated=false`, `WS_EX_NOACTIVATE`, `Topmost`). Clicks on
  it must NEVER move focus from the app being dictated into.
- Contents: elapsed timer (left), 26-bar audio-reactive waveform (center, driven
  by live mic peak mapped dB -50..-15 to 0..1, fast attack / slow release, flat
  dotted line when silent), hint text "Pick a mode · Esc cancels" (right),
  2-line rolling transcript below (front-trimmed: newest words always visible).

## 2. Three mode chips on the pill (v7.8) + mode-first stop (v8.1)
- Chips: Summarize / Normal / Professional. Click selects (highlight), click
  again unselects. Selection resets every new recording.
- MODE_REQUIRED=1 (default): the stop tap does nothing until a chip is picked;
  refusing taps flashes the chip row + shows a hint line. Esc cancels the
  recording outright (discard, nothing pasted).
- Delivery: Normal = paste raw formatted transcript. Summarize = detail-
  EXPANDING rewrite for AI prompts (output >= 3/5 input length or paste raw).
  Professional = clean text/email prose (grammar fixed, filler cut, facts kept,
  no em or en dashes ever; >= 3/10 length gate). Any LLM failure pastes raw.

## 3. Command mode (edit selection by voice)
- Alt + hotkey tap: capture the current selection (try UI Automation
  TextPattern first, fall back to synthesized Ctrl-C with clipboard restore),
  record, transcript = edit instruction, LLM rewrite pastes over the still-
  highlighted selection. Any failure pastes NOTHING.

## 4. Self-learning dictionary + snippets
- `learned-words.txt`: `Canonical|variant1,variant2` per line, hot-reloaded.
  Applied as case/spell regex fixes post-decode AND appended to the whisper
  prompt under a ~200-token budget (whisper prompts silently truncate past
  ~220 tokens; never exceed).
- `snippets`: `name = expansion` (`\n` = newline). Spoken "snippet <name>"
  expands in place. `ptt.ps1 learn` / `ptt.ps1 snippets` commands.

## 5. Config parity
- LANGUAGE (en/auto/...), WHISPER_MODE (strong gain + VAD gate 0.15),
  PRO_APPS (auto-Professional when the foreground process matches),
  POLISH_APPS, POLISH_ASK legacy flow when MODE_REQUIRED=0, CHUNK_SECONDS
  rolling transcription, MAX_RECORD_SECONDS hard cap (never ship without it).

## 6. Anti-hallucination decode contract (do not skip)
- Silero VAD mandatory (silence hallucinates text), beam 5, entropy 2.4-2.8,
  repetition collapse in the formatter (1 word x6, 2 words x5, phrases x4),
  filler strip (um/uh but never "uh huh"), spoken "new line"/"new paragraph"/
  bullet commands only at punctuation-flanked boundaries.

## 7. Lease check-in (v8.2, REQUIRED before any customer install)
- Config LICENSE_KEY (from the nesso.tech dashboard) + LICENSE_URL
  (default https://nesso.tech/api/license).
- On launch + every 12h: POST {"key": "<uuid>"} to LICENSE_URL. Response
  {"valid": bool, "reason": ...}. valid=false -> disarm recording (hotkey
  refuses with a "manage at nesso.tech" message); an in-flight session still
  finishes (never eat words mid-recording).
- Network failure: honor the last successful check-in for 72h (stamp file),
  then disarm. Empty LICENSE_KEY = dev build, enforcement off.

## 8. Robustness lessons already paid for on Mac
- Pin the built-in mic by default; Bluetooth default inputs drop silently.
- Survive sleep/wake without restart (WASAPI device-invalidation handling is
  the Windows analog of the Mac's AVAudioEngine -10868 lesson).
- Clipboard paste with change-count guard, restore the user's clipboard.
- A watchdog on every external process; the daemon never exits to self-heal.

## 9. Privacy parity (Mac v8.5, REQUIRED before any customer install)
- Config keys PRIVACY_MODE (default 1), HISTORY_DAYS (default 7), KEEP_LAST_CLIP (default 0).
- Route every transcript log call through one helper. With PRIVACY_MODE on, write
  only a word count and the first 6 hex of the SHA-256, never the spoken text.
- With PRIVACY_MODE off, append AES-GCM sealed records to history.enc, keyed by a
  secret held in Windows DPAPI (the analog of the Mac Keychain). Never store the
  key beside the data, and never write plaintext to the log either way.
- Restrict the log file ACL to the current user, and delete dictation artifacts on
  the failure path too, not just on success.
- One-time migration on first launch of the new build: strip existing plaintext
  transcripts out of the log, delete retained audio, and log how many were removed.

## 10. Per-platform activation (v8.6)
- Send {"key", "machine", "platform": "windows"} to LICENSE_URL. One license
  activates Mac, Windows, and iOS, but only ONCE per platform. A second, different
  machine on an already-claimed platform is refused with "platform_already_activated".

## 11. v8.8: remembered mode, Finish button, predictive preload
- DONE (this build): SELECTED_MODE — the tray Mode menu (Professional / Summarize /
  Normal / AI Agent / AI Extend / Automatic) writes SELECTED_MODE to the config the
  moment it is picked, so the pick survives a full app restart. An explicit pick
  beats PRO_APPS/POLISH_APPS routing, exactly like a HUD mode pick on the Mac.
  agent/expand ride the same proxy call; they skip the length trust gate (briefs
  restructure rather than preserve) but keep the refusal gate.
- NOT PORTED YET (Mac-only until Windows grows a rolling-transcription engine):
  the recording-pill Finish button (push-to-live: stop and paste instantly with
  the pre-run rewrite if ready, else the raw words) and predictive preload (the
  speculative tail decode fires the active mode's rewrite DURING the pre-stop
  pause, keyed on the exact transcript so resumed speech invalidates it). The
  Windows pipeline decodes whole-file after stop, so there is no mid-recording
  transcript to pre-polish yet. Port order: chunked decode -> spec tail ->
  text-keyed polish race -> overlay Finish button.

## 12. v8.10 code-mode fallbacks (PORTED, static-review only)

LocalModes.cs mirrors the Mac build's localModeTransform: deterministic,
code-only versions of summarize / professional / agent / expand that run when
the polish proxy cannot answer (no key, no license, offline), so a picked mode
always changes the output instead of silently pasting raw. Wired at both
failure points in PolishClient.Apply (proxy null + trust-gate fail).
NOT compiled or executed on Windows yet: verify with `ptt-dictate.exe` by
killing network access, dictating in each mode, and confirming the Goal /
Constraints / Done when / Context brief (agent), bullets (summarize), and
Open questions (expand) appear.

## 13. v8.11 self-tuning modes (PARTIALLY PORTED, static-review only)

PORTED into LocalModes.cs: the v2 scored clause classifier (weighted cues, two
strictness levels, better-shaped brief wins, ambiguous clauses stay in Goal),
the number-preservation fact guardrail wired into Transform, and hot-loaded
custom cues from mode-rules in the app data dir (%LOCALAPPDATA%\ptt-dictate).
NOT PORTED: per-app learned mode defaults (Mac records every explicit HUD pick
per bundle id in mode-usage; 3+ picks at 60%+ make that mode the app's default).
Windows needs foreground-at-dictation tracking first — recording the foreground
process at tray-menu click time would capture the shell, not the target app,
and poison the habit file. Wire it to the process captured at recording start.

UPDATE v8.12: per-app habit learning is now PORTED (static-review only). The
foreground process is captured at RECORDING START into DictationSession.LastApp,
so a tray Mode pick teaches ModeHabits (mode-usage file) against the dictation
target instead of the shell. SelectMode ordering now matches the Mac build:
picked-this-recording > learned habit > sticky mode > app routing > default.
Also ported: comma run-on splitting + "$4,500" money formatting (Professional),
domain-aware Open questions (Expand), extra safe contractions. Verify on a real
Windows machine: pick a mode 3x in one app, dictate without picking, and expect
"Learned mode for <app>" in the log.

## 14. v8.14 sound-alike learning (NOT PORTED)

The Mac build corrects near-misses of learned words phonetically (Soundex +
edit distance, all words must match for multi-word names, real-dictionary-word
guard for single words) and self-promotes a twice-seen spelling into
learned-words.txt. Windows has NO learned-dictionary subsystem at all yet
(static WHISPER_PROMPT only), so port order is: learned-words.txt loader +
exact variant regex in TextFormatter first, then the fuzzy pass + promotion.

## 15. v8.17 cloud engine (PORTED, static-review only)
Cloud-first transcription is wired: `WhisperTranscriber.TranscribeAsync` calls
`TryCloudTranscribeAsync` (hosted engine, `x-license-key` header + machine +
platform=windows form fields) before the local whisper-cli path, and the local
requires now sit AFTER the cloud attempt so a future thin-shell build can ship
without bundled weights. Config keys `CLOUD` / `TRANSCRIBE_URL` mirror the Mac
daemon. NOT executed on a real Windows box yet, same standing caveat as the
Ed25519 verify.
KNOWN GAP: `License.cs` check-in payload still omits the `platform` field, so
Windows check-ins register as platform=mac on the server (per-platform seat
binding is weakened until fixed). The cloud transcribe path DOES send
platform=windows correctly.

## 16. v8.18 decode race + movable/resizable pill (NOT PORTED)
Mac now (a) routes ChunkEngine decodes: speculative passes LOCAL-only, chunk
decodes cloud-preferred, tails/whole-files RACE cloud vs local and paste the
fastest (both timings logged as telemetry); (b) makes the HUD pill draggable
(isMovableByWindowBackground) and edge-resizable (borderless+.resizable,
min 420x150, transcript area absorbs all extra space, waveform hides when the
top bar is tight, session-remembered custom frame, default restored on
restart). Windows: port the race into WhisperTranscriber (cloud task + local
task, first non-empty wins) and drag/resize into DictationOverlay
(WS_THICKFRAME or manual hit-testing). Port order: race first (UX), overlay
second.

## 17. v8.21 smarter modes (PORTED, static-review only)
LocalModes.cs mirrors the Mac v8.21 upgrades: expanded filler rules (trailing
throwaways, function-word stutter doubles), 18 new unambiguous contractions,
question-mark inference, greeting/sign-off on their own lines, 2-3 sentence
paragraphing, Summarize Decisions block + wider list/topic cues, agent cue
additions (goal verbs, deadline constraints, attempt context, outcome done),
Expand's 6 new domains with performance ranked above report. NOT ported:
the Settings keyword editor (Windows has no settings UI; mode-rules file
editing still applies) and paste-time smart typography (needs a verified
single paste point + foreground-app check on a real Windows box).

## 18. v8.22 multi-channel microphone (VERIFY ON WINDOWS)
Mac bug: Apple's built-in mic array reports THREE channels, and
AVAudioFormat(streamDescription:) returns nil above two channels, so every
captured buffer was silently dropped and dictation looked like a dead mic.
Fixed with an explicit discrete channel layout plus a channel-0 downmix.
Windows uses NAudio/WASAPI, a different API, so it is NOT affected by this
specific nil, BUT the same class of bug applies: confirm AudioRecorder
handles a >2-channel capture device (WaveFormat.Channels > 2) by downmixing
rather than assuming mono, and test on a machine with a mic array.
