# NessoTalk

Local-first voice dictation. Tap a key, talk, and clean polished text lands in
whatever app you're using. Transcription runs on-device; AI rewrites (Summarize
/ Professional / command-mode edits) are opt-in per dictation.

Live site: https://nesso.tech (nessotalk.vercel.app)

## Layout

- **`/` (repo root)**: the website. Next.js 14 + Tailwind + Supabase auth.
  Landing page, 3-click trial signup, dashboard with plan + platform downloads.
- **`apps/mac/`**: the macOS daemon (Swift, v8.1). Right ⌘ tap-toggle, waveform
  pill HUD with mode chips, whisper.cpp local transcription, AI polish modes,
  command mode, self-learning dictionary, snippets. `./ptt build` compiles,
  signs, and (re)starts it.
- **`apps/windows/`**: the Windows port (.NET 9 + PowerShell), originally built
  by Jeremy Hayes (github.com/jeremymhayes/ptt-dictate-windows, MIT). See
  `apps/windows/WINDOWS_PARITY.md` for the task list bringing it to Mac v8.1
  behavior.

## Site dev

```bash
npm install
npm run dev        # needs .env.local with Supabase URL + anon key
npm run typecheck
```

Deploy: `npx vercel --prod --yes` (project: acuntels-projects/nessotalk).

## Product rules

- No em or en dashes in any user-facing copy, ever.
- Transcription stays local. Only explicit AI modes send text (never audio) out.
- Draft honest numbers only; no invented user counts.
