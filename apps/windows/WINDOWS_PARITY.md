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

## 7. Robustness lessons already paid for on Mac
- Pin the built-in mic by default; Bluetooth default inputs drop silently.
- Survive sleep/wake without restart (WASAPI device-invalidation handling is
  the Windows analog of the Mac's AVAudioEngine -10868 lesson).
- Clipboard paste with change-count guard, restore the user's clipboard.
- A watchdog on every external process; the daemon never exits to self-heal.
