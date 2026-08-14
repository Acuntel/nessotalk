import Cocoa
import AVFoundation
import ApplicationServices
import CoreGraphics
import Carbon.HIToolbox
import CoreAudio
import AudioToolbox
import CoreMedia
import CryptoKit

// ===================== Paths =====================
let HOME = NSHomeDirectory()
let MODEL = "\(HOME)/.whisper-models/ggml-large-v3-turbo-q5_0.bin"
let VAD_MODEL = "\(HOME)/.whisper-models/ggml-silero-v5.1.2.bin"
// Homebrew installs to /opt/homebrew on Apple silicon and /usr/local on Intel.
// Hardcoding the Apple silicon prefix meant every Intel Mac failed the startup
// guard below and launchd crash-looped it forever with no window and no message.
// Declared as a plain function over literals only, so it stays safe to call from
// file scope before the other globals exist (see the Config.load() ordering rule).
func _which(_ tool: String) -> String {
    for p in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/opt/local/bin/"] {
        if FileManager.default.isExecutableFile(atPath: p + tool) { return p + tool }
    }
    return "/opt/homebrew/bin/" + tool   // keep a stable string for logs
}
let WHISPER = _which("whisper-cli")
let FFMPEG = _which("ffmpeg")
let LOG = "\(HOME)/.dictation/ptt.log"
let CONFIG_PATH = "\(HOME)/.dictation/config"

// ===================== Config =====================
// Runtime tunables live in ~/.dictation/config (KEY=VALUE, # comments) so they
// can be changed WITHOUT a rebuild — a rebuild resets the TCC grants, a config
// edit + `ptt restart` does not.
// The dir must exist before Config.load() writes defaults / log() appends.
private let _dictationDirReady: Void = {
    try? FileManager.default.createDirectory(atPath: "\(HOME)/.dictation", withIntermediateDirectories: true)
}()
struct Config {
    var vadThreshold = 0.3   // lowered from 0.5: 0.5 gated out quiet/trailing words
    var maxRecordSeconds: TimeInterval = 2700      // 45 min; auto-stop guard for a forgotten mic
    var liveCaptions = true
    var captionInterval = 2.0                       // seconds between live-caption passes
    var captionWindow = 10.0                        // seconds of trailing audio per pass
    var captionModel = "\(HOME)/.whisper-models/ggml-base.en-q5_1.bin"
    // Which microphone to record from. "builtin" (default) pins capture to the
    // Mac's built-in mic so dictation never rides a flaky Bluetooth link (AirPods
    // as the system default input is what produced the -66681 failures). "default"
    // follows the system default input; any other value is matched as a
    // case-insensitive substring of a device name. A built-in-mic fallback always
    // kicks in if the chosen device produces no audio.
    var inputDevice = "builtin"
    // Pre-decode audio conditioning (ffmpeg): high-pass + FFT denoise + dynamic
    // normalize, applied before whisper. Recovers quiet/ducked words and strips
    // line/room noise — closes most of the gap to Wispr-class tools. Auto-skipped
    // if ffmpeg is missing.
    var preprocess = true
    // Call mode: for phone/VoIP dictation, where the OS echo-canceller ducks your
    // own mic mid-call. Switches preprocessing to an aggressive denoise/AGC chain
    // and pushes the VAD gate down so ducked words aren't trimmed. Toggle: `ptt call`.
    var callMode = false
    // Rolling transcription: while recording, finished audio is cut at natural
    // pauses roughly every this-many seconds and transcribed in the background
    // with the FULL pipeline, so the wait after stop is only the last chunk —
    // seconds, regardless of how long the recording ran. Values under 20 disable
    // it (every stop then decodes the whole file in one shot, the old behavior).
    var chunkSeconds = 30.0   // 60 predates the resident server; 30 halves the tail
    // Speculative tail: when speech goes quiet, decode the un-cut tail DURING
    // the pause so a stop tap finds the transcript already made. A resumed
    // sentence just invalidates the guess. Costs an occasional extra decode.
    var speculative = true
    // Resident whisper-server (launchd com.brady.ptt-whisper-server, port 8977):
    // model stays loaded between dictations — skips the 1-2s load every CLI
    // spawn pays. Any server trouble auto-falls back to whisper-cli.
    var useServer = true
    // AI prompt-polish: when dictating INTO an AI app (frontmost bundle id
    // matches polishApps), rewrite the transcript into a structured, detail-
    // preserving document — resolved self-corrections, lists, expanded (never
    // compressed) thoughts — via the POLISH_MODEL Claude model. Never adds
    // requirements; any failure pastes the raw transcript.
    // Say "verbatim" as the first word of a dictation to skip it once.
    var polish = true
    var polishApps = "terminal,iterm,claude,code,cursor,warp"
    var polishMinWords = 12
    // Optional sk-ant API key -> fast direct-API path (~2-3s). Empty = use the
    // `claude` CLI (subscription auth, slower by ~3-5s of spawn+auth overhead).
    var polishKey = ""
    // Ask-first popup: when a transcript qualifies for polish, show a floating
    // Summarize / Keep-the-Same panel instead of auto-polishing. The panel never
    // steals focus; an unanswered panel resolves to Keep after polishAskTimeout.
    // 0 disables the popup and restores the old auto-polish behavior.
    var polishAsk = true
    var polishAskTimeout = 30.0
    // Claude model for the polish rewrite (API + CLI paths; Groq path is fixed
    // to llama). sonnet-5 for detail-preserving expansion; claude-haiku-4-5 is
    // the faster/lighter fallback if polish feels slow.
    var polishModel = "claude-sonnet-5"
    // ---- NessoTalk v8.0 (Wispr-parity) ----
    // Decode language: "en", "es", ... or "auto" (whisper detects, can switch
    // mid-recording). Live captions stay English (caption model is English-only).
    var language = "en"
    // Whisper mode: dictate at a whisper — aggressive gain/denoise + a low VAD
    // gate. Forces the CLI decode path (the server's VAD gate is fixed at
    // launch, same constraint as call mode). Toggle: `ptt whisper`.
    var whisperMode = false
    // Auto-Professional targets: dictating into these apps (bundle-id substring,
    // like POLISH_APPS) rewrites the gist into clean text/email prose
    // automatically — Wispr-style tone-by-app. Empty disables.
    var proApps = "mobilesms,messages,mail,outlook,whatsapp,telegram,slack,discord"
    // v8.3 stop-anytime: the stop tap ALWAYS lands. DEFAULT_MODE is what a stop
    // with NO chip clicked delivers: summarize | professional | normal | ask
    // ("ask" restores the v7.5 popup flow). Chips are optional overrides.
    var defaultMode = "summarize"
    // v8.8 remembered mode: whichever mode was last picked on the recording
    // pill. The click writes it here, launch reads it back, so the pick
    // survives a full quit/reopen. "ask" = nothing remembered yet.
    var selectedMode = "ask"
    // v8.2 lease: customer builds carry a LICENSE_KEY (from the nesso.tech
    // dashboard). The daemon checks in on launch + every 12h; revoked/expired
    // accounts disarm recording. Empty key = enforcement off (dev build).
    var licenseKey = ""
    var licenseUrl = "https://nesso.tech/api/license"
    // Server-side AI proxy: with a license key set, the rewrite modes run on
    // nesso.tech under our API key instead of needing the customer's own.
    // A cracked copy can't reach it without an active license.
    var polishProxyUrl = "https://nesso.tech/api/polish"
    // v8.17 cloud pivot: transcription runs on NessoTalk's own hosted engine,
    // license-gated on every request. Local whisper stays as the automatic
    // fallback so dictation keeps working through any engine or network
    // outage — cloud-first, never cloud-only.
    var cloud = true
    var transcribeUrl = "https://nessotalk-engine-production.up.railway.app/transcribe"
    // Key code of the modifier that starts and stops dictation.
    var hotkey: UInt16 = 54
    // Privacy is the default, not an opt-in. With this on, what you said is
    // never written to disk in readable form anywhere.
    var privacyMode = true
    // Anything retained is dropped after this many days. 0 keeps nothing.
    var historyDays = 7
    // Keeping the last raw recording around was a debugging convenience. Off.
    var keepLastClip = false
    // Standing instruction for how the writing should always sound, e.g.
    // "warm and direct" or "formal, never casual". Applied to every rewrite.
    var style = ""

    static func load() -> Config {
        var c = Config()
        guard let raw = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else {
            let defaults = """
            # ptt-dictate runtime config — edit then run `ptt restart` (no rebuild needed)
            VAD_THRESHOLD=\(c.vadThreshold)
            MAX_RECORD_SECONDS=\(Int(c.maxRecordSeconds))
            LIVE_CAPTIONS=1
            CAPTION_INTERVAL=\(c.captionInterval)
            CAPTION_WINDOW=\(Int(c.captionWindow))
            CAPTION_MODEL=\(c.captionModel)
            # builtin | default | <substring of a device name>
            INPUT_DEVICE=builtin
            # Pre-decode denoise + dynamic-normalize via ffmpeg (recovers quiet words)
            PREPROCESS=1
            # Phone/VoIP dictation: aggressive denoise + lower VAD gate. Toggle: `ptt call`
            CALL_MODE=0
            # Rolling transcription: pre-transcribe finished audio every ~N seconds while
            # still recording, so long dictations paste in seconds. <20 disables.
            CHUNK_SECONDS=30
            # Speculative tail: decode during the pause before the stop tap. 0 disables.
            SPECULATIVE=1
            # Resident whisper-server for near-instant pastes (auto-fallback to CLI). 0 disables.
            SERVER=1
            # AI prompt-polish: restructure dictation into a precise prompt when the
            # frontmost app matches POLISH_APPS. Say "verbatim" first to skip once.
            POLISH=1
            POLISH_APPS=terminal,iterm,claude,code,cursor,warp
            POLISH_MIN_WORDS=12
            # Optional sk-ant key for the fast direct-API polish path (else `claude` CLI)
            POLISH_KEY=
            # Ask before polishing: Summarize / Keep-the-Same popup after each qualifying
            # dictation. Unanswered panels paste the raw transcript after the timeout.
            POLISH_ASK=1
            POLISH_ASK_TIMEOUT=30
            # Claude model for the Summarize rewrite (claude-haiku-4-5 = faster/lighter)
            POLISH_MODEL=claude-sonnet-5
            # Privacy mode: your words are never written to disk. 0 keeps an
            # encrypted history instead, unlocked by a key held in your Keychain.
            PRIVACY_MODE=1
            # Anything retained is deleted after this many days. 0 keeps nothing.
            HISTORY_DAYS=7
            # Keep the audio of the last dictation on disk. Off by default.
            KEEP_LAST_CLIP=0
            # Decode language: en, es, ... or auto (captions stay English)
            LANGUAGE=en
            # Whisper mode: quiet-voice dictation (strong gain + low VAD gate). Toggle: ptt whisper
            WHISPER_MODE=0
            # Auto-Professional apps (bundle-id substrings). Empty disables.
            PRO_APPS=mobilesms,messages,mail,outlook,whatsapp,telegram,slack,discord
            # What a stop with NO chip clicked delivers: summarize | professional |
            # normal | ask (ask restores the old popup flow)
            DEFAULT_MODE=summarize
            # Remembered mode: whichever mode you last picked on the recording pill.
            # Written automatically when you click one; survives restarts.
            SELECTED_MODE=ask
            """
            try? defaults.write(toFile: CONFIG_PATH, atomically: true, encoding: .utf8)
            return c
        }
        for line in raw.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let key = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            // Clamped: this file is hand-edited, and a bad value must degrade,
            // not trap (e.g. negative CAPTION_WINDOW would crash UInt64()).
            case "VAD_THRESHOLD":      c.vadThreshold = min(1, max(0, Double(val) ?? c.vadThreshold))
            case "MAX_RECORD_SECONDS": c.maxRecordSeconds = max(10, Double(val) ?? c.maxRecordSeconds)
            case "LIVE_CAPTIONS":      c.liveCaptions = (val == "1" || val.lowercased() == "true")
            case "CAPTION_INTERVAL":   c.captionInterval = max(0.5, Double(val) ?? c.captionInterval)
            case "CAPTION_WINDOW":     c.captionWindow = min(30, max(2, Double(val) ?? c.captionWindow))
            case "CAPTION_MODEL":      c.captionModel = (val as NSString).expandingTildeInPath
            case "INPUT_DEVICE":       if !val.isEmpty { c.inputDevice = val }
            case "PREPROCESS":         c.preprocess = (val == "1" || val.lowercased() == "true")
            case "CALL_MODE":          c.callMode = (val == "1" || val.lowercased() == "true")
            case "CHUNK_SECONDS":      c.chunkSeconds = min(600, max(0, Double(val) ?? c.chunkSeconds))
            case "SERVER":             c.useServer = (val == "1" || val.lowercased() == "true")
            case "SPECULATIVE":        c.speculative = (val == "1" || val.lowercased() == "true")
            case "POLISH":             c.polish = (val == "1" || val.lowercased() == "true")
            case "POLISH_APPS":        if !val.isEmpty { c.polishApps = val }
            case "POLISH_MIN_WORDS":   c.polishMinWords = max(1, Int(Double(val) ?? Double(c.polishMinWords)))
            case "POLISH_KEY":         c.polishKey = val
            case "POLISH_ASK":         c.polishAsk = (val == "1" || val.lowercased() == "true")
            case "POLISH_ASK_TIMEOUT": c.polishAskTimeout = max(5, Double(val) ?? c.polishAskTimeout)
            case "POLISH_MODEL":       if !val.isEmpty { c.polishModel = val }
            case "LANGUAGE":           if !val.isEmpty { c.language = val.lowercased() }
            case "WHISPER_MODE":       c.whisperMode = (val == "1" || val.lowercased() == "true")
            case "PRO_APPS":           c.proApps = val
            // Inline literal on purpose: Config.load() must never read another
            // file-scope global (V8.5 segfault). Mirrors SETTINGS_MODES.
            case "DEFAULT_MODE":       if ["summarize", "professional", "normal", "raw", "ask", "agent", "expand"].contains(val.lowercased()) { c.defaultMode = val.lowercased() == "raw" ? "normal" : val.lowercased() }
            case "SELECTED_MODE":      if ["summarize", "professional", "normal", "raw", "ask", "agent", "expand"].contains(val.lowercased()) { c.selectedMode = val.lowercased() == "raw" ? "normal" : val.lowercased() }
            case "LICENSE_KEY":        c.licenseKey = val
            case "LICENSE_URL":        if !val.isEmpty { c.licenseUrl = val }
            case "POLISH_PROXY_URL":   if !val.isEmpty { c.polishProxyUrl = val }
            case "CLOUD":              c.cloud = (val == "1" || val.lowercased() == "true")
            case "TRANSCRIBE_URL":     if !val.isEmpty { c.transcribeUrl = val }
            case "STYLE":              c.style = val
            case "PRIVACY_MODE":       c.privacyMode = (val == "1" || val.lowercased() == "true")
            case "HISTORY_DAYS":       c.historyDays = min(365, max(0, Int(Double(val) ?? Double(c.historyDays))))
            case "KEEP_LAST_CLIP":     c.keepLastClip = (val == "1" || val.lowercased() == "true")
            // Validated against literals on purpose: Config.load() runs before
            // the TRIGGER_KEYS global is initialized, and touching it here
            // dereferences uninitialized memory and segfaults at launch.
            case "HOTKEY":             if let k = UInt16(val), [54, 55, 56, 58, 59, 60, 61, 62].contains(k) { c.hotkey = k }
            default: break
            }
        }
        return c
    }
}
let cfg = Config.load()

// Trigger = a solo press of the Right Command key: press and release it with no
// other key in between. Tap once -> start, tap again -> stop. There is NO max
// hold time — holding it a beat too long still toggles. Pressing any other key
// while it's down makes it a normal modifier (Right-⌘ shortcuts still work).
// The trigger key is configurable from Settings. Each entry pairs the key code
// with the device-specific modifier bit that says "this exact key is down",
// which is what lets us tell left Command from right Command.
struct TriggerKey { let code: UInt16; let bit: UInt; let name: String }
let TRIGGER_KEYS: [TriggerKey] = [
    TriggerKey(code: 54, bit: 0x10, name: "Right Command"),
    TriggerKey(code: 55, bit: 0x08, name: "Left Command"),
    TriggerKey(code: 61, bit: 0x40, name: "Right Option"),
    TriggerKey(code: 58, bit: 0x20, name: "Left Option"),
    TriggerKey(code: 62, bit: 0x2000, name: "Right Control"),
    TriggerKey(code: 59, bit: 0x1000, name: "Left Control"),
    TriggerKey(code: 60, bit: 0x0004, name: "Right Shift"),
    TriggerKey(code: 56, bit: 0x0002, name: "Left Shift"),
]
func triggerKey(forCode code: UInt16) -> TriggerKey {
    TRIGGER_KEYS.first { $0.code == code } ?? TRIGGER_KEYS[0]
}
let LEFT_CMD_BIT: UInt = 0x08            // NX_DEVICELCMDKEYMASK

// Vocabulary / style primer fed to whisper. Biases decoding toward Brady's
// project + tech vocab. NOTE: needs -mc >= prompt token count or whisper
// silently truncates it (keeps only the LAST tokens — the old -mc 0 killed it
// entirely). KEEP THIS LEAN (~100 tokens): a fat prompt measurably slows every
// decode window (--carry-initial-prompt re-feeds it constantly) and over-biases
// the decoder toward the name list at the expense of ordinary words — the
// 2026-07-27 45-name version made dictation slower AND worse. Spelling/casing
// repair belongs in the glossary below (regex post-fix, zero decode cost).
let VOCAB_PROMPT = "Notes on software projects: Nesso, StolenMule, KARL, Meemoo, Sabify, Supabase, Vercel, Railway, Tailwind, Next.js, TypeScript, Capacitor, Twilio, Resend, Anthropic, Claude, Bedrock, Postgres, Higgsfield, ElevenLabs, LawPay, Smokeball, Redfin, Zillow, IOLTA, daemon, Wispr Flow."

// ===================== self-learning dictionary + snippets =====================
// learned-words.txt: one entry per line, `Canonical|variant1,variant2` (variants
// optional). Appended via `ptt learn`, hot-reloaded on every use — no restart.
// Applied two ways: a zero-decode-cost regex fix in formatTranscript, and
// appended to the decode prompt while the ~220-token truncation ceiling allows.
let LEARNED_PATH = "\(HOME)/.dictation/learned-words.txt"
struct LearnedWord { let canonical: String; let variants: [String] }
func loadLearnedWords() -> [LearnedWord] {
    guard let raw = try? String(contentsOfFile: LEARNED_PATH, encoding: .utf8) else { return [] }
    var out: [LearnedWord] = []
    for line in raw.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#") else { continue }
        let parts = t.split(separator: "|", maxSplits: 1)
        let canonical = String(parts[0]).trimmingCharacters(in: .whitespaces)
        guard !canonical.isEmpty else { continue }
        let variants = parts.count > 1
            ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        out.append(LearnedWord(canonical: canonical, variants: variants))
    }
    return out
}

// ── Sound-alike learning (v8.14) ─────────────────────────────────────────────
// A spoken phrase that SOUNDS like a word already clarified gets corrected to
// it, even when whisper picked a spelling nobody listed. Strictly bounded so it
// can never invent or steal: it only rewrites what was actually spoken (the
// v8.13 rule), every word of a multi-word match must be phonetically close to
// its counterpart, and a single-word match is skipped when whisper heard a real
// dictionary word — trust the ear over the hunch. A corrected spelling seen
// twice graduates into learned-words.txt as an exact variant, so the dictionary
// literally teaches itself from usage.

// Crude but effective sound-alike hashing ("hays"/"hayes"/"haze" all -> H200).
func soundexKey(_ word: String) -> String {
    let w = word.lowercased().filter { $0.isLetter }
    guard let first = w.first else { return "" }
    let codes: [Character: Character] = [
        "b": "1", "f": "1", "p": "1", "v": "1",
        "c": "2", "g": "2", "j": "2", "k": "2", "q": "2", "s": "2", "x": "2", "z": "2",
        "d": "3", "t": "3", "l": "4", "m": "5", "n": "5", "r": "6",
    ]
    var out = String(first).uppercased()
    var last: Character? = codes[first]
    for ch in w.dropFirst() {
        let code = codes[ch]
        if let code = code, code != last { out.append(code) }
        if ch != "h" && ch != "w" { last = code }
    }
    return out.padding(toLength: 4, withPad: "0", startingAt: 0)
}

func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a.lowercased()), y = Array(b.lowercased())
    if x.isEmpty { return y.count }
    if y.isEmpty { return x.count }
    var prev = Array(0...y.count)
    for i in 1...x.count {
        var cur = [i] + Array(repeating: 0, count: y.count)
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[y.count]
}

// The system dictionary keeps sound-alike matching honest: a real English word
// whisper heard stays untouched in single-word matches ("memo" is never
// dragged into "Meemoo"; "meemo" is fair game). Loaded once, on first use.
enum SystemWords {
    static let common: Set<String> = {
        guard let raw = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(raw.split(separator: "\n").map { $0.lowercased() })
    }()
}

func wordsSoundClose(_ heard: String, _ target: String) -> Bool {
    if heard.lowercased() == target.lowercased() { return true }
    let d = editDistance(heard, target)
    if d <= 1 { return true }
    return soundexKey(heard) == soundexKey(target) && d <= 2
}

func fuzzyLearnedPass(_ input: String) -> String {
    let entries = loadLearnedWords()
    guard !entries.isEmpty else { return input }
    var tokens = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    for entry in entries {
        let canonWords = entry.canonical.split(separator: " ").map(String.init)
        let k = canonWords.count
        guard k >= 1 else { continue }
        var i = 0
        while tokens.count >= k, i <= tokens.count - k {
            let window = Array(tokens[i..<(i + k)])
            let stripped = window.map { $0.trimmingCharacters(in: .punctuationCharacters) }
            let heardPhrase = stripped.joined(separator: " ")
            if heardPhrase.lowercased() != entry.canonical.lowercased(),
               !stripped.contains(where: { $0.isEmpty }),
               zip(stripped, canonWords).allSatisfy({ wordsSoundClose($0.0, $0.1) }),
               k > 1 || !SystemWords.common.contains(stripped[0].lowercased()) {
                // Keep whatever punctuation trailed the last word of the window.
                let trailing = String(window[k - 1].reversed()
                    .prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
                tokens.replaceSubrange(i..<(i + k), with: [entry.canonical + trailing])
                log("≈ sound-alike corrected to \(entry.canonical)")
                noteFuzzyVariant(heardPhrase.lowercased(), canonical: entry.canonical)
                i += 1
                continue
            }
            // Split-word catch: whisper renders one-word names as two words
            // ("nesso talk" for NessoTalk). For a one-word canonical, try
            // joining two adjacent words — allowed only when at least one of
            // them is not ordinary English, so real phrases stay untouched.
            if k == 1, i + 1 < tokens.count {
                let second = tokens[i + 1].trimmingCharacters(in: .punctuationCharacters)
                let joined = stripped[0] + second
                if !stripped[0].isEmpty, !second.isEmpty,
                   wordsSoundClose(joined, entry.canonical),
                   !SystemWords.common.contains(stripped[0].lowercased())
                    || !SystemWords.common.contains(second.lowercased()) {
                    let trailing = String(tokens[i + 1].reversed()
                        .prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
                    tokens.replaceSubrange(i..<(i + 2), with: [entry.canonical + trailing])
                    log("≈ sound-alike corrected to \(entry.canonical) (split word)")
                    noteFuzzyVariant((stripped[0] + " " + second).lowercased(), canonical: entry.canonical)
                }
            }
            i += 1
        }
    }
    return tokens.joined(separator: " ")
}

// First sighting is remembered as a candidate; the second promotes it into
// learned-words.txt, where the exact-regex pass (zero risk) takes over.
func noteFuzzyVariant(_ heard: String, canonical: String) {
    let candPath = NSHomeDirectory() + "/.dictation/.variant-candidates"
    let entry = canonical + "|" + heard
    var lines = (try? String(contentsOfFile: candPath, encoding: .utf8))?
        .split(separator: "\n").map(String.init) ?? []
    if lines.contains(entry) {
        lines.removeAll { $0 == entry }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(toFile: candPath, atomically: true, encoding: .utf8)
        promoteVariant(heard, canonical: canonical)
    } else {
        lines.append(entry)
        try? (lines.joined(separator: "\n") + "\n")
            .write(toFile: candPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candPath)
    }
}

func promoteVariant(_ variant: String, canonical: String) {
    guard let raw = try? String(contentsOfFile: LEARNED_PATH, encoding: .utf8) else { return }
    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (i, line) in lines.enumerated() {
        let parts = line.split(separator: "|", maxSplits: 1)
        guard let c = parts.first,
              String(c).trimmingCharacters(in: .whitespaces) == canonical else { continue }
        let existing = parts.count > 1 ? String(parts[1]) : ""
        let already = existing.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !already.contains(variant) else { return }
        lines[i] = canonical + "|" + (existing.isEmpty ? variant : existing + "," + variant)
        try? lines.joined(separator: "\n").write(toFile: LEARNED_PATH, atomically: true, encoding: .utf8)
        log("· dictionary taught itself a new spelling for \(canonical)")
        return
    }
}

// snippets: `name = expansion` per line (\\n in the expansion = newline). Saying
// "snippet <name>" (or "insert snippet <name>") mid-dictation expands in place.
let SNIPPETS_PATH = "\(HOME)/.dictation/snippets"
func loadSnippets() -> [String: String] {
    guard let raw = try? String(contentsOfFile: SNIPPETS_PATH, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for line in raw.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
        let name = String(t[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
        let body = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !body.isEmpty { out[name] = body.replacingOccurrences(of: "\\n", with: "\n") }
    }
    return out
}

// Decode prompt = the lean hand-tuned vocab + learned words, capped well under
// whisper's ~220-token silent-truncation ceiling (V7.1 lesson: past the ceiling
// the prompt silently keeps only its LAST tokens — never let growth do that).
// v8.13: learned words NO LONGER ride the decode prompt. RCA 2026-08-06: the
// prompt is a suggestion whisper will happily hallucinate into a transcript on
// mumbly or vaguely-similar audio — "Jeremy Hayes" (the lone learned word)
// appeared in a dictation that never mentioned him, because every recording was
// primed with the name. Learning is regex-only now (formatTranscript step 4c):
// it fires only when whisper actually heard a listed variant, which can fix a
// spelling but can never invent a word that wasn't spoken.
func effectivePrompt() -> String {
    return VOCAB_PROMPT
}

// ===================== Logging =====================
let logTimeFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    return f
}()
func log(_ s: String) {
    let line = "[\(logTimeFmt.string(from: Date()))] " + s + "\n"
    let data = line.data(using: .utf8)!
    // O_APPEND: log() is called from several queues — each write must be an
    // atomic append, not an unsynchronized seek+write.
    // 0600: the log is for this user alone. Anything running as them could
    // otherwise read the whole dictation history, which was the original leak.
    let fd = open(LOG, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    if fd >= 0 {
        FileHandle(fileDescriptor: fd, closeOnDealloc: true).write(data)
    }
    FileHandle.standardError.write(data)
}

func playSound(_ name: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/\(name).aiff"]
    try? p.run()
}

// ===================== Wispr-Flow-style formatting =====================
// Cleanup pipeline applied to whisper's raw output before it is inserted:
//   1. drop non-speech annotation lines/tokens ([BLANK_AUDIO], (laughs), …)
//   2. collapse hallucination loops (the same 1-6 word phrase repeated 3+ times)
//   3. strip filler words (um, uh, erm …)
//   4. spoken layout commands: "new line" -> \n, "new paragraph" -> \n\n
//   5. whitespace + capitalization polish, terminal punctuation

func regexReplace(_ text: String, _ pattern: String, _ template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return re.stringByReplacingMatches(in: text, range: range, withTemplate: template)
}

// Collapse runs where the same 1-6 word phrase repeats 3+ times in a row —
// the signature of a whisper hallucination loop ("in the room. in the room. …").
// Comparison ignores case and punctuation; the first occurrence is kept.
func collapseRepeats(_ text: String) -> String {
    let words = text.split(separator: " ").map(String.init)
    guard words.count > 3 else { return text }
    func norm(_ w: String) -> String {
        return w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
    }
    var out: [String] = []
    var i = 0
    var collapsedAny = false
    while i < words.count {
        var advanced = false
        // Smallest unit first, so a 3-word loop isn't half-eaten by a 6-word window.
        var n = 1
        while n <= 6 {
            if i + 2 * n <= words.count {
                var reps = 1
                while i + (reps + 1) * n <= words.count {
                    var match = true
                    for k in 0..<n where norm(words[i + reps * n + k]) != norm(words[i + k]) {
                        match = false; break
                    }
                    if match { reps += 1 } else { break }
                }
                // Legit speech repeats short units ("really really really",
                // "no, no, no", "five five five") — only collapse runs too long
                // to be intentional. Real hallucination loops run dozens deep.
                let minReps = n == 1 ? 6 : (n == 2 ? 5 : 4)
                if reps >= minReps {
                    out.append(contentsOf: words[i..<(i + n)])
                    i += reps * n
                    advanced = true
                    collapsedAny = true
                    break
                }
            }
            n += 1
        }
        if !advanced { out.append(words[i]); i += 1 }
    }
    if collapsedAny { log("⚠️ collapsed a repetition loop in the transcript") }
    return out.joined(separator: " ")
}

func formatTranscript(_ raw: String) -> String {
    // 1. Per-line: drop empties and whole-line non-speech annotations.
    var text = raw.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty
            && !($0.hasPrefix("[") && $0.hasSuffix("]"))
            && !($0.hasPrefix("(") && $0.hasSuffix(")")) }
        .joined(separator: " ")

    // Inline non-speech tags whisper sometimes emits mid-line.
    text = regexReplace(text, "\\[[A-Z_ ]+\\]", " ")
    text = regexReplace(text, "(?i)\\((?:laugh|sigh|music|noise|silence|cough|applause)[^)]*\\)", " ")

    // 2. Kill hallucination loops before anything else.
    text = collapseRepeats(text)

    // 3. Fillers. Conservative list — only unambiguous verbal tics. "uh huh"
    //    (an affirmation) is exempt. Commas on BOTH sides collapse to one comma
    //    ("eggs, um, milk" -> "eggs, milk"); otherwise the filler just vanishes.
    let filler = "(?:um+|uhm+|erm+|mhm+|uh+(?!\\s+huh\\b))"
    text = regexReplace(text, "(?i),\\s*\\b\(filler)\\b[,.]\\s*", ", ")
    text = regexReplace(text, "(?i)(?:^|(?<=[\\s.]))\(filler)\\b[,.]?(?=\\s|$)", " ")

    // 4. Spoken layout commands. Only when the phrase stands alone — flanked by
    //    punctuation (how whisper renders a command said with a pause) — so prose
    //    like "a new line of products" or the word "newline" passes through.
    //    A sentence-ending . ! ? before the command is kept; commas are dropped.
    text = regexReplace(text, "(?i)([.!?])[ \\t]*\\bnew paragraph\\b[,.;:]*[ \\t]*", "$1\n\n")
    text = regexReplace(text, "(?i)[,;:][ \\t]*\\bnew paragraph\\b[,.;:]*[ \\t]*", "\n\n")
    text = regexReplace(text, "(?i)^[ \\t]*new paragraph\\b[,.;:]*[ \\t]*", "\n\n")
    text = regexReplace(text, "(?i)([.!?])[ \\t]*\\bnew line\\b[,.;:]*[ \\t]*", "$1\n")
    text = regexReplace(text, "(?i)[,;:][ \\t]*\\bnew line\\b[,.;:]*[ \\t]*", "\n")
    text = regexReplace(text, "(?i)^[ \\t]*new line\\b[,.;:]*[ \\t]*", "\n")

    // 4a. Spoken list bullets, Wispr-style: "we need three things dash fix login
    //     dash ship it" -> "…three things.\n- Fix login\n- Ship it". Only the
    //     standalone word at a clause boundary (start of text/line or right
    //     after punctuation — how whisper renders it said with a pause) becomes
    //     a bullet; "a dash of salt" and "100-meter dash" pass through.
    let bullet = "(?:dash|bullet(?:\\s+point)?)"
    text = regexReplace(text, "(?i)([.!?])[ \\t]*\\b\(bullet)\\b[,.;:]*[ \\t]+", "$1\n- ")
    text = regexReplace(text, "(?i)[,;:][ \\t]*\\b\(bullet)\\b[,.;:]*[ \\t]+", "\n- ")
    text = regexReplace(text, "(?i)(?<=\\n)[ \\t]*\(bullet)\\b[,.;:]*[ \\t]+", "- ")
    text = regexReplace(text, "(?i)^[ \\t]*\(bullet)\\b[,.;:]*[ \\t]+", "- ")

    // 4b. Custom dictionary, Wispr-style: case-fix Brady's proper nouns that
    //     whisper hears right but casings wrong (or slightly misspells).
    let glossary: [(String, String)] = [
        ("(?i)\\bn[ei]s+o+\\b", "Nesso"),
        ("(?i)\\bstolen ?mule\\b", "StolenMule"),
        ("(?i)\\bsupabase\\b", "Supabase"),
        ("(?i)\\bvercel\\b", "Vercel"),
        ("(?i)\\brailway\\b", "Railway"),
        ("(?i)\\bnext ?\\.? ?js\\b", "Next.js"),
        ("(?i)\\btypescript\\b", "TypeScript"),
        ("(?i)\\btailwind\\b", "Tailwind"),
        ("(?i)\\btwilio\\b", "Twilio"),
        ("(?i)\\bclaude\\b", "Claude"),
        ("(?i)\\banthropic\\b", "Anthropic"),
        ("(?i)\\bbedrock\\b", "Bedrock"),
        ("(?i)\\bpostgres\\b", "Postgres"),
        ("(?i)\\bredfin\\b", "Redfin"),
        ("(?i)\\bzillow\\b", "Zillow"),
        ("(?i)\\biolta\\b", "IOLTA"),
        ("(?i)\\bd[ae]+mon\\b", "daemon"),
        ("(?i)\\bgithub\\b", "GitHub"),
        // "carl" too: whisper writes the human spelling even with the prompt.
        // If Brady ever works with a real Carl, drop the second alternative.
        ("(?i)\\b(?:karl|carl)\\b", "KARL"),
        // NOT m[ei]+m+oo? — that would swallow the real word "memo".
        ("(?i)\\b(?:meemoo|meemo|meemu|mimoo|mimu|memoo)\\b", "Meemoo"),
        ("(?i)\\bdell?o\\b", "Dello"),
        ("(?i)\\bsabify\\b", "Sabify"),
        ("(?i)\\bhiggs?field\\b", "Higgsfield"),
        ("(?i)\\beleven ?labs\\b", "ElevenLabs"),
        ("(?i)\\blaw ?pay\\b", "LawPay"),
        ("(?i)\\bsmoke ?ball\\b", "Smokeball"),
        ("(?i)\\bremotion\\b", "Remotion"),
        ("(?i)\\bgoat ?counter\\b", "GoatCounter"),
        ("(?i)\\bacuntel\\b", "Acuntel"),
        ("(?i)\\binkept\\b", "Inkept"),
        ("(?i)\\brobin ?hood\\b", "Robinhood"),
        ("(?i)\\bwispr ?flow\\b", "Wispr Flow"),
        ("(?i)\\bdu ?page\\b", "DuPage"),
        ("(?i)\\busc\\b", "USC")
    ]
    for (pattern, replacement) in glossary {
        text = regexReplace(text, pattern, replacement)
    }

    // 4c. Self-learning dictionary (`ptt learn`): case/spell-fix learned words,
    //     including any known mishearings. Zero decode cost, hot-reloaded.
    for w in loadLearnedWords() {
        var alts = [NSRegularExpression.escapedPattern(for: w.canonical)]
        alts += w.variants.map { NSRegularExpression.escapedPattern(for: $0) }
        text = regexReplace(text, "(?i)\\b(?:" + alts.joined(separator: "|") + ")\\b",
                            NSRegularExpression.escapedTemplate(for: w.canonical))
    }

    // 4c2. Sound-alike pass: near-misses of clarified words correct themselves
    //      and, once seen twice, teach the dictionary the new spelling.
    text = fuzzyLearnedPass(text)

    // 4d. Snippets: spoken "snippet <name>" expands to the saved text.
    for (name, body) in loadSnippets() {
        let esc = NSRegularExpression.escapedPattern(for: name)
        text = regexReplace(text, "(?i)\\b(?:insert )?snippet[,]?\\s+" + esc + "\\b[,.]?",
                            NSRegularExpression.escapedTemplate(for: body))
    }

    // 5. Whitespace polish: collapse runs of spaces, tidy space-before-punctuation.
    text = regexReplace(text, "[ \\t]+", " ")
    text = regexReplace(text, " ([,.!?;:])", "$1")
    text = regexReplace(text, " *\\n *", "\n")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)

    // Capitalize sentence starts (start of text, after .!? + space, after newline).
    var chars = Array(text)
    var capitalizeNext = true
    // Token before a '.' that does NOT end a sentence ("e.g. lowercase").
    let abbreviations: Set<String> = ["etc", "vs", "mr", "mrs", "dr", "st", "jr", "sr", "inc", "approx"]
    func endsAbbreviation(_ dotIdx: Int) -> Bool {
        var j = dotIdx - 1
        var token = ""
        while j >= 0, chars[j].isLetter { token.insert(chars[j], at: token.startIndex); j -= 1 }
        if token.count == 1, j >= 0, chars[j] == "." { return true }   // e.g. / i.e. / U.S.
        return abbreviations.contains(token.lowercased())
    }
    for idx in 0..<chars.count {
        let c = chars[idx]
        if capitalizeNext, c.isLetter {
            chars[idx] = Character(c.uppercased())
            capitalizeNext = false
        } else if c == "\n" {
            capitalizeNext = true
        } else if c == "." || c == "!" || c == "?" {
            // Only a real sentence boundary (punctuation then whitespace/end) —
            // not the dot inside "Next.js" or after an abbreviation.
            capitalizeNext = ((idx + 1 == chars.count) || chars[idx + 1].isWhitespace)
                && !(c == "." && endsAbbreviation(idx))
        } else if c.isLetter || c.isNumber {
            capitalizeNext = false
        }
    }
    text = String(chars)

    // Case-sensitive tokens the capitalizer would break — re-fix after it runs.
    for (pattern, replacement) in [("(?i)\\bios\\b", "iOS"), ("(?i)\\bmacos\\b", "macOS"),
                                   ("(?i)\\biphone\\b", "iPhone"), ("(?i)\\bipad\\b", "iPad"),
                                   ("\\bNpm\\b", "npm"), ("\\bNpx\\b", "npx")] {
        text = regexReplace(text, pattern, replacement)
    }

    // The English first-person pronoun is always capitalized. This lives here in
    // formatTranscript rather than in cleanedSentences so that Normal mode gets it
    // too: Normal previously produced "Yesterday i met sarah and i think i should",
    // which is the single most visible defect in the most-used mode. Contracted
    // forms are included; "i.e." is excluded because the period is part of it.
    text = regexReplace(text, "\\bi\\b(?!\\.)", "I")
    for (pattern, replacement) in [("\\bi'm\\b", "I'm"), ("\\bi've\\b", "I've"),
                                   ("\\bi'll\\b", "I'll"), ("\\bi'd\\b", "I'd")] {
        text = regexReplace(text, pattern, replacement)
    }

    // Terminal punctuation, Wispr-style: only for sentence-length dictation.
    if text.split(separator: " ").count >= 4, let last = text.last,
       last.isLetter || last.isNumber {
        text += "."
    }
    return text
}

// ===================== WAV helpers =====================
// CoreAudio's in-flight WAVE file has a stale header (frame count 0) but the
// raw PCM keeps appending after the 'data' chunk header — captions read it live.
func findWavDataOffset(_ path: String) -> UInt64? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { fh.closeFile() }
    let head = fh.readData(ofLength: 8192)
    guard head.count >= 44,
          head[0...3].elementsEqual("RIFF".utf8),
          head[8...11].elementsEqual("WAVE".utf8) else { return nil }
    var off = 12
    while off + 8 <= head.count {
        let id = head[off..<off+4]
        let size = Int(head[off+4]) | Int(head[off+5]) << 8 | Int(head[off+6]) << 16 | Int(head[off+7]) << 24
        if id.elementsEqual("data".utf8) { return UInt64(off + 8) }
        if size > head.count { return nil } // stale pre-data chunk size — abort to the 4096 fallback
        off += 8 + size + (size & 1)        // chunks are even-padded
    }
    return nil
}

@inline(__always) func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
@inline(__always) func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

// 44-byte canonical 16 kHz / mono / s16 WAV header. dataBytes is the PCM payload
// length; it is written as 0 up front for a streaming recording and patched on stop.
func wavHeader(dataBytes: UInt32) -> Data {
    var d = Data()
    d.append("RIFF".data(using: .ascii)!); d.append(le32(36 &+ dataBytes))
    d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); d.append(le32(16))
    d.append(le16(1)); d.append(le16(1))                 // PCM, mono
    d.append(le32(16000)); d.append(le32(32000))         // rate, bytes/sec
    d.append(le16(2)); d.append(le16(16))                // block align, bits
    d.append("data".data(using: .ascii)!); d.append(le32(dataBytes))
    return d
}

func writeWav16kMono(_ pcm: Data, to path: String) {
    var d = wavHeader(dataBytes: UInt32(pcm.count))
    d.append(pcm)
    try? d.write(to: URL(fileURLWithPath: path))
}

// Scan the trailing `lookback` bytes of [from, to) — byte offsets relative to
// the WAV data chunk, even-aligned — for the quietest 320ms window. Returns an
// even cut offset at that window's center if it is genuinely quiet (absolute
// room-tone level, or well under the local speech level — speech-gap RMS sits
// 10-30× below voiced audio), else nil. Used to cut chunks and commit captions
// at real pauses so a boundary never lands mid-word.
func quietCutPoint(fh: FileHandle, dataOff: UInt64, from: UInt64, to: UInt64, lookback: UInt64) -> UInt64? {
    guard to > from else { return nil }
    let lb = min(to - from, lookback) & ~1
    let start = to - lb
    fh.seek(toFileOffset: dataOff + start)
    let data = fh.readData(ofLength: Int(lb))
    let samples = data.count / 2
    let hop = 1280                                        // 80ms at 16kHz
    guard samples >= hop * 8 else { return nil }
    var rms: [Double] = []
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        let p = buf.bindMemory(to: Int16.self)
        var i = 0
        while i + hop <= samples {
            var acc = 0.0
            for j in i..<(i + hop) { let v = Double(p[j]); acc += v * v }
            rms.append((acc / Double(hop)).squareRoot())
            i += hop
        }
    }
    guard rms.count >= 4 else { return nil }
    let mean = rms.reduce(0, +) / Double(rms.count)
    var bestIdx = -1
    var bestVal = Double.greatestFiniteMagnitude
    for i in 0...(rms.count - 4) {
        let w = (rms[i] + rms[i + 1] + rms[i + 2] + rms[i + 3]) / 4
        if w < bestVal { bestVal = w; bestIdx = i }
    }
    guard bestIdx >= 0, bestVal < max(120, mean * 0.25) else { return nil }
    var cut = start + UInt64((bestIdx + 2) * hop * 2)
    cut &= ~1
    guard cut > from + 32000, cut < to else { return nil }    // keep ≥1s before the cut
    return cut
}

// Mean RMS of [from, to) — byte offsets relative to the WAV data chunk.
func rangeRMS(fh: FileHandle, dataOff: UInt64, from: UInt64, to: UInt64) -> Double {
    guard to > from else { return 0 }
    fh.seek(toFileOffset: dataOff + from)
    let data = fh.readData(ofLength: Int(min(to - from, 320000)))   // cap at 10s
    let n = data.count / 2
    guard n > 0 else { return 0 }
    var acc = 0.0
    data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        let p = buf.bindMemory(to: Int16.self)
        for i in 0..<n { let v = Double(p[i]); acc += v * v }
    }
    return (acc / Double(n)).squareRoot()
}

// ===================== Audio input device selection (Core Audio) =====================
// The whole class of "-66681 / stops halfway / empty transcription" failures came
// from AVAudioRecorder driving a 16 kHz AudioQueue against whatever the SYSTEM
// default input was — which, for Brady, is usually his AirPods Max over Bluetooth.
// We now enumerate real input devices so we can pin capture to the built-in mic.

struct InputDevice { let id: AudioDeviceID; let name: String; let builtIn: Bool }

func inputChannelCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = withUnsafeMutablePointer(to: &name) {
        $0.withMemoryRebound(to: UInt8.self, capacity: Int(size)) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
    }
    if st == noErr, let n = name { return n.takeRetainedValue() as String }
    return "input"
}

func deviceIsBuiltIn(_ id: AudioDeviceID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var transport = UInt32(0); var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else { return false }
    return transport == kAudioDeviceTransportTypeBuiltIn
}

func allInputDevices() -> [InputDevice] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { inputChannelCount($0) > 0 }
              .map { InputDevice(id: $0, name: deviceName($0), builtIn: deviceIsBuiltIn($0)) }
}

func defaultInputDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
          dev != 0 else { return nil }
    return dev
}

// Ordered list of devices to try, best-first. The built-in mic is ALWAYS appended
// as the final fallback so a missing/renamed/dead preferred device degrades to the
// one input that can't drop — this is the backbone of "indestructible".
func resolveInputCandidates(_ pref: String) -> [InputDevice] {
    let devices = allInputDevices()
    var ordered: [InputDevice] = []
    let p = pref.lowercased().trimmingCharacters(in: .whitespaces)
    switch p {
    case "builtin", "built-in", "":
        break                                            // built-in appended below
    case "default", "system":
        if let d = defaultInputDeviceID(), let m = devices.first(where: { $0.id == d }) { ordered.append(m) }
    default:
        if let m = devices.first(where: { $0.name.lowercased().contains(p) }) { ordered.append(m) }
    }
    if let b = devices.first(where: { $0.builtIn }), !ordered.contains(where: { $0.id == b.id }) {
        ordered.append(b)
    }
    return ordered
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid)
    guard st == noErr, let u = uid else { return nil }
    return u.takeRetainedValue() as String
}

// Ordered AVCaptureDevices to try, best-first, with the built-in mic ALWAYS last so
// a missing/renamed preferred device degrades to the one input that can't drop.
func resolveAVDevices(_ pref: String) -> [AVCaptureDevice] {
    let p = pref.lowercased().trimmingCharacters(in: .whitespaces)
    var ordered: [AVCaptureDevice] = []
    func builtInAV() -> AVCaptureDevice? {
        guard let b = allInputDevices().first(where: { $0.builtIn }),
              let uid = deviceUID(b.id) else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }
    switch p {
    case "builtin", "built-in", "":
        break
    case "default", "system":
        if let d = AVCaptureDevice.default(for: .audio) { ordered.append(d) }
    default:
        if let m = allInputDevices().first(where: { $0.name.lowercased().contains(p) }),
           let uid = deviceUID(m.id), let dev = AVCaptureDevice(uniqueID: uid) { ordered.append(dev) }
    }
    if let b = builtInAV(), !ordered.contains(where: { $0.uniqueID == b.uniqueID }) { ordered.append(b) }
    if ordered.isEmpty, let d = AVCaptureDevice.default(for: .audio) { ordered.append(d) }
    return ordered
}

// ===================== Audio capture (AVCaptureSession, native rate -> 16 kHz) =====================
// We capture via AVCaptureSession (AVCaptureAudioDataOutput), NOT AVAudioEngine:
// after sleep, AVAudioEngine's coupled input/output audio unit can fail start() with
// -10868 (kAudioUnitErr_FormatNotSupported) while the device is perfectly healthy —
// proven by AVCaptureSession capturing fine in the exact same wedged state. This
// path has no such coupling, so dictation survives sleep with NO coreaudiod restart
// and NO admin rights. Each sample buffer is resampled to 16 kHz / mono / s16 and
// streamed to the WAV ourselves; a flow watchdog swaps to the built-in mic if the
// chosen device delivers nothing.
final class AudioCapturer: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Result { let bytes: UInt64; let peak: Int16; let frames: UInt64; let device: String }

    private var session: AVCaptureSession?
    private let sampleQueue = DispatchQueue(label: "ptt.audio.capture")
    private var converter: AVAudioConverter?
    private var convRate: Double = 0
    private var convChannels: AVAudioChannelCount = 0
    private let writer = DispatchQueue(label: "ptt.audio.writer")
    private var fh: FileHandle?
    private var dataBytes: UInt64 = 0
    private var framesSeen: UInt64 = 0
    private var peak: Int16 = 0
    private var active = false
    // Pause gate. Set while the Settings window is open so the recording holds
    // its place instead of capturing the user configuring the app. Gating the
    // ingest point rather than stopping the AVCaptureSession keeps the buffer,
    // the converter, and the device open, so resume is instant and seamless.
    private var paused = false
    // Temporary capture instrumentation, off unless PTT_CAPDEBUG=1.
    private let capDebug = ProcessInfo.processInfo.environment["PTT_CAPDEBUG"] == "1"
    private var capCallbacks = 0
    private var capFails = 0
    private(set) var deviceName = "?"
    // Live input level for the HUD waveform (0..1, called on MAIN). Set once at
    // daemon startup; nil in CLI modes so tests never touch AppKit.
    var onLevel: ((Float) -> Void)?

    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                       channels: 1, interleaved: true)!

    // Returns true if SOME device started. onSwap fires if we fell back to another
    // input mid-start; onDead fires only if even the built-in mic yields no audio.
    func start(path: String, preference: String,
               onSwap: @escaping (String) -> Void, onDead: @escaping () -> Void) -> Bool {
        var candidates = resolveAVDevices(preference)
        if candidates.isEmpty, let d = AVCaptureDevice.default(for: .audio) { candidates = [d] }
        for (idx, c) in candidates.enumerated() where startSession(device: c, path: path) {
            armFlowWatchdog(path: path, remaining: Array(candidates[(idx + 1)...]),
                            onSwap: onSwap, onDead: onDead)
            return true
        }
        return false
    }

    private func startSession(device: AVCaptureDevice, path: String) -> Bool {
        let sess = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), sess.canAddInput(input) else {
            log("· AVCapture: cannot open \(device.localizedName)")
            return false
        }
        sess.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard sess.canAddOutput(output) else { return false }
        sess.addOutput(output)

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else { return false }
        handle.write(wavHeader(dataBytes: 0))
        writer.sync { self.fh = handle; self.dataBytes = 0; self.framesSeen = 0; self.peak = 0 }
        converter = nil; convRate = 0; convChannels = 0
        // A pause must never outlive its recording: if one leaked past a stop
        // (recording ended while a pause-holder was still open), the next
        // session would capture pure silence and look like a dead mic.
        paused = false
        deviceName = device.localizedName
        session = sess
        sess.startRunning()
        guard sess.isRunning else {
            log("· AVCapture: session failed to start on \(device.localizedName)")
            sess.stopRunning()
            try? handle.close(); writer.sync { self.fh = nil }
            session = nil
            return false
        }
        active = true
        return true
    }

    // Delegate (on sampleQueue): bridge each captured CMSampleBuffer into an
    // AVAudioPCMBuffer, then run the same resample/measure/write path as before.
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        if capDebug, capCallbacks < 3 {
            capCallbacks += 1
            let n = CMSampleBufferGetNumSamples(sb)
            var desc = "samples=\(n) paused=\(paused)"
            if let fd = CMSampleBufferGetFormatDescription(sb),
               let a = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                let s = a.pointee
                desc += " rate=\(s.mSampleRate) ch=\(s.mChannelsPerFrame) bits=\(s.mBitsPerChannel)"
                desc += " flags=\(s.mFormatFlags) bytesPerFrame=\(s.mBytesPerFrame)"
            } else { desc += " NO-FORMAT-DESC" }
            log("· capdebug cb: \(desc)")
        }
        if paused { onLevel.map { cb in DispatchQueue.main.async { cb(0) } }; return }
        if let buf = pcmBuffer(from: sb) { ingest(buf) }
    }

    // Hold the recording without tearing anything down. Safe to call repeatedly.
    func pauseCapture()  { paused = true }
    func resumeCapture() { paused = false }
    var isPaused: Bool { paused }

    private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else {
            if capDebug, capFails < 3 { capFails += 1; log("· capdebug: no format description") }
            return nil
        }
        var asbd = asbdPtr.pointee
        // 🚨 v8.22: Apple's built-in mic ARRAY reports THREE channels. Plain
        // AVAudioFormat(streamDescription:) can only infer a layout for mono
        // and stereo and returns nil above that, so every buffer was dropped
        // and dictation looked like a dead microphone while the hardware was
        // perfectly healthy. Above two channels the layout must be explicit.
        var built = AVAudioFormat(streamDescription: &asbd)
        if built == nil, asbd.mChannelsPerFrame > 2,
           let layout = AVAudioChannelLayout(
               layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(asbd.mChannelsPerFrame)) {
            built = AVAudioFormat(streamDescription: &asbd, channelLayout: layout)
        }
        guard let fmt = built else {
            if capDebug, capFails < 3 {
                capFails += 1
                log("· capdebug: AVAudioFormat init failed ch=\(asbd.mChannelsPerFrame)")
            }
            return nil
        }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else {
            if capDebug, capFails < 3 { capFails += 1; log("· capdebug: PCM buffer alloc failed n=\(n)") }
            return nil
        }
        buf.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                              into: buf.mutableAudioBufferList)
        if st != noErr {
            if capDebug, capFails < 3 { capFails += 1; log("· capdebug: CopyPCMData failed status=\(st)") }
            return nil
        }
        // A discrete multi-channel layout is not something AVAudioConverter can
        // be trusted to downmix, so collapse to mono here and hand the rest of
        // the pipeline the single-channel shape it has always seen. Channel 0
        // is the primary capsule; averaging the array would comb-filter and
        // could fold in a reference channel.
        if buf.format.channelCount > 2 { return monoFromFirstChannel(buf) }
        return buf
    }

    private func monoFromFirstChannel(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buf.floatChannelData,
              let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: buf.format.sampleRate,
                                          channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: buf.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = buf.frameLength
        let n = Int(buf.frameLength)
        if buf.format.isInterleaved {
            let ch = Int(buf.format.channelCount)
            let p = src[0]
            for i in 0..<n { dst[i] = p[i * ch] }
        } else {
            dst.update(from: src[0], count: n)
        }
        return out
    }

    // Runs on the audio render thread: convert -> measure -> hand bytes to the writer.
    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard buf.frameLength > 0, buf.format.sampleRate > 0 else { return }
        // (Re)build the converter from the buffer's ACTUAL format — the node may
        // report a different rate/channel count than expected, or change on a swap.
        if converter == nil || convRate != buf.format.sampleRate || convChannels != buf.format.channelCount {
            converter = AVAudioConverter(from: buf.format, to: target)
            convRate = buf.format.sampleRate
            convChannels = buf.format.channelCount
        }
        guard let conv = converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        let status = conv.convert(to: out, error: nil) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return buf
        }
        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        let p = ch[0]
        var localPeak: Int16 = 0
        for i in 0..<n {
            let a = Int16(clamping: abs(Int32(p[i])))
            if a > localPeak { localPeak = a }
        }
        if let cb = onLevel {
            // Peak -> dB -> 0..1: -50dB (room tone) maps to 0, -15dB (loud speech)
            // to 1. The waveform's own frame timer does the smoothing.
            let db = 20 * log10(max(1, Double(localPeak)) / 32767)
            let lvl = Float(min(1, max(0, (db + 50) / 35)))
            DispatchQueue.main.async { cb(lvl) }
        }
        let data = Data(bytes: p, count: n * 2)
        writer.async { [weak self] in
            guard let self = self, let fh = self.fh else { return }
            fh.write(data)
            self.dataBytes += UInt64(n * 2)
            self.framesSeen += UInt64(n)
            if localPeak > self.peak { self.peak = localPeak }
        }
    }

    // If the chosen device produced zero frames ~1.3s in, it's dead — swap to the
    // next candidate (ultimately the built-in mic). Re-checks once more after the swap.
    private func armFlowWatchdog(path: String, remaining: [AVCaptureDevice],
                                 onSwap: @escaping (String) -> Void, onDead: @escaping () -> Void) {
        writer.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self = self, self.active, self.framesSeen == 0 else { return }
            DispatchQueue.main.async {
                self.teardown(patch: false)
                let nexts = remaining.isEmpty ? resolveAVDevices("builtin") : remaining
                for c in nexts where self.startSession(device: c, path: path) {
                    onSwap(c.localizedName)
                    self.writer.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                        if let s = self, s.active, s.framesSeen == 0 { DispatchQueue.main.async { onDead() } }
                    }
                    return
                }
                onDead()
            }
        }
    }

    @discardableResult
    func stop() -> Result {
        return teardown(patch: true)
    }

    @discardableResult
    private func teardown(patch: Bool) -> Result {
        if let s = session { s.stopRunning() }          // blocks until capture stops -> no more delegates
        session = nil
        active = false
        var snap = Result(bytes: 0, peak: 0, frames: 0, device: deviceName)
        writer.sync {
            snap = Result(bytes: self.dataBytes, peak: self.peak, frames: self.framesSeen, device: self.deviceName)
            if let fh = self.fh {
                if patch, self.dataBytes <= UInt64(UInt32.max) - 36 {
                    let n = UInt32(self.dataBytes)
                    try? fh.seek(toOffset: 4);  fh.write(le32(36 &+ n))
                    try? fh.seek(toOffset: 40); fh.write(le32(n))
                }
                try? fh.close()
                self.fh = nil
            }
        }
        return snap
    }
}


// ===================== privacy =====================
// The rule: what you said never lands on disk in readable form. The log records
// that a dictation happened and how big it was, and a short hash so you can
// prove a given transcript is the one that was produced, but never the words.
//
// If you turn PRIVACY_MODE off because you want your history back, the history
// is still encrypted. The key lives in the macOS Keychain, which is hardware
// backed and never sits next to the data, so the files on disk are unreadable
// on any machine but this one, by anyone but you.
let HISTORY_PATH = "\(HOME)/.dictation/history.enc"
private let KEYCHAIN_SERVICE = "com.brady.ptt-dictate"
private let KEYCHAIN_ACCOUNT = "history-key"

func shortHash(_ text: String) -> String {
    let d = SHA256.hash(data: Data(text.utf8))
    return d.compactMap { String(format: "%02x", $0) }.joined().prefix(6).description
}

// Fetch the history key, creating it on first use. Stored with
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: it never syncs anywhere and
// never leaves this Mac.
func historyKey() -> SymmetricKey? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KEYCHAIN_SERVICE,
        kSecAttrAccount as String: KEYCHAIN_ACCOUNT,
        kSecReturnData as String: true,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
       let data = item as? Data, data.count == 32 {
        return SymmetricKey(data: data)
    }
    let fresh = SymmetricKey(size: .bits256)
    let raw = fresh.withUnsafeBytes { Data($0) }
    var add: [String: Any] = query
    add.removeValue(forKey: kSecReturnData as String)
    add[kSecValueData as String] = raw
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemDelete(query as CFDictionary)
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
        log("⚠️ could not store the history key in the Keychain, so no history is being kept")
        return nil
    }
    return fresh
}

// One sealed record per line: timestamp, then the AES-GCM box in base64. The
// timestamp is outside the box on purpose, so retention can drop old entries
// without ever decrypting anything.
func appendHistory(_ text: String, tag: String) {
    guard let key = historyKey(),
          let sealed = try? AES.GCM.seal(Data("\(tag)\t\(text)".utf8), using: key),
          let box = sealed.combined?.base64EncodedString() else { return }
    let line = "\(Int(Date().timeIntervalSince1970))\t\(box)\n"
    if !FileManager.default.fileExists(atPath: HISTORY_PATH) {
        FileManager.default.createFile(atPath: HISTORY_PATH, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
    }
    if let fh = FileHandle(forWritingAtPath: HISTORY_PATH) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        try? fh.close()
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HISTORY_PATH)
}

// The single place spoken content is allowed to reach a log call.
func logTranscript(_ text: String, tag: String) {
    let words = text.split(separator: " ").count
    if cfg.privacyMode {
        log("✓\(tag) \(words) words · \(shortHash(text))")
    } else {
        appendHistory(text, tag: tag)
        log("✓\(tag) \(words) words · \(shortHash(text)) · saved to encrypted history")
    }
}

// Drop retained data older than the retention window, and clear temp files left
// behind by sessions that died mid-flight.
func retentionSweep() {
    let cutoff = Date().timeIntervalSince1970 - Double(cfg.historyDays) * 86_400
    if cfg.historyDays == 0 {
        try? FileManager.default.removeItem(atPath: HISTORY_PATH)
    } else if let raw = try? String(contentsOfFile: HISTORY_PATH, encoding: .utf8) {
        let kept = raw.split(separator: "\n").filter { line in
            guard let ts = Double(line.split(separator: "\t").first ?? "") else { return false }
            return ts >= cutoff
        }
        let dropped = raw.split(separator: "\n").count - kept.count
        if dropped > 0 {
            try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n"))
                .write(toFile: HISTORY_PATH, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HISTORY_PATH)
            log("· retention: removed \(dropped) history entries past \(cfg.historyDays) days")
        }
    }
    // Log lines age out too, so a long-lived install does not accumulate a
    // record of when every dictation happened.
    if cfg.historyDays > 0, let raw = try? String(contentsOfFile: LOG, encoding: .utf8) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 4000 {
            let kept = lines.suffix(2000)
            try? (kept.joined(separator: "\n") + "\n").write(toFile: LOG, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: LOG)
        }
    }
}

// Runs once, on the first launch of a build that has privacy. Strips the
// readable transcripts earlier versions wrote, and removes the retained clip.
func purgeLegacyPlaintext() {
    let marker = "\(HOME)/.dictation/.privacy_migrated"
    guard !FileManager.default.fileExists(atPath: marker) else { return }
    var removed = 0
    if let raw = try? String(contentsOfFile: LOG, encoding: .utf8) {
        let kept = raw.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let leaks = line.contains("] ✓ ") || line.contains("· raw: ") || line.contains("· cmd instruction: ")
            if leaks { removed += 1 }
            return !leaks
        }
        try? (kept.joined(separator: "\n")).write(toFile: LOG, atomically: true, encoding: .utf8)
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: LOG)
    if FileManager.default.fileExists(atPath: "/tmp/ptt_last.wav") {
        try? FileManager.default.removeItem(atPath: "/tmp/ptt_last.wav")
        removed += 1
    }
    FileManager.default.createFile(atPath: marker, contents: nil)
    log("🔒 privacy migration: removed \(removed) plaintext transcripts and retained clips from earlier versions")
}

// ===================== waveform (Wispr-Flow-style HUD) =====================
// Audio-reactive bar visualizer: a row of thin rounded bars that sit as a flat
// dotted line in silence and bloom center-out with the live mic level. Levels
// arrive on MAIN via setLevel (AudioCapturer.onLevel maps peak->0..1); a 30fps
// timer animates per-bar motion so the pill feels alive without ever touching
// the mic itself. All state main-thread-only.
final class WaveformView: NSView {
    private let barCount = 26
    private let barWidth: CGFloat = 3.5
    private let gap: CGFloat = 3.5
    private var heights: [CGFloat]
    private var phases: [Double] = []
    private var speeds: [Double] = []
    private var held: Float = 0          // peak held between frames, decays in step()
    private var smoothed: CGFloat = 0
    private var timer: Timer?
    private var t: Double = 0

    override init(frame: NSRect) {
        heights = Array(repeating: 2.5, count: barCount)
        super.init(frame: frame)
        for _ in 0..<barCount {
            phases.append(Double.random(in: 0..<(2 * .pi)))
            speeds.append(Double.random(in: 5.5...9.5))
        }
    }
    required init?(coder: NSCoder) { return nil }

    func setLevel(_ l: Float) { held = max(held, min(1, l)) }

    func start() {
        stop()
        let tm = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tm, forMode: .common)
        timer = tm
    }

    func stop() {
        timer?.invalidate(); timer = nil
        held = 0; smoothed = 0
        heights = heights.map { _ in 2.5 }
        needsDisplay = true
    }

    private func step() {
        t += 1.0 / 30.0
        let lv = CGFloat(held)
        held *= 0.55                                   // buffers arrive faster than frames; decay the hold
        // Fast attack, slower release: speech snaps the bars up, pauses breathe down.
        smoothed += (lv - smoothed) * (lv > smoothed ? 0.55 : 0.16)
        let maxH = bounds.height
        for i in 0..<barCount {
            let x = Double(i) / Double(barCount - 1)
            let env = 0.30 + 0.70 * sin(.pi * x)       // center-weighted swell
            let wob = 0.62 + 0.38 * sin(t * speeds[i] + phases[i])
            let idle = 0.05 * (0.5 + 0.5 * sin(t * 2.0 + phases[i]))
            let h = max(2.5, (CGFloat(env * wob) * smoothed + CGFloat(idle)) * maxH)
            heights[i] += (h - heights[i]) * 0.5
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let total = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var x = (bounds.width - total) / 2
        NSColor.white.withAlphaComponent(0.92).setFill()
        for h in heights {
            let r = NSRect(x: x, y: (bounds.height - h) / 2, width: barWidth, height: h)
            NSBezierPath(roundedRect: r, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

// How a finished transcript is delivered. .ask = no HUD pick, fall through to
// the existing flow (Summarize/Professional/Keep popup or auto-polish).
enum DeliverMode: CaseIterable {
    case ask, summarize, raw, professional, agent, expand

    // The five pickable modes, in the order they appear in the HUD menu.
    static var pickable: [DeliverMode] { [.professional, .summarize, .raw, .agent, .expand] }

    var label: String {
        switch self {
        case .ask:          return "Ask"
        case .summarize:    return "Summarize"
        case .raw:          return "Normal"
        case .professional: return "Professional"
        case .agent:        return "AI Agent"
        case .expand:       return "AI Extend"
        }
    }

    // Shown on hover, next to the ⓘ. Concrete before/after beats description.
    var example: String {
        switch self {
        case .ask:
            return "Asks you which mode to use after you stop."
        case .summarize:
            return "Restructures a long ramble into a clear, organized document.\n\nYou say: \"ok so the login thing, tokens expire after an hour but the refresh isn't firing, and also we should log it\"\n\nYou get: a structured writeup with each point unpacked and the reasoning kept."
        case .raw:
            return "Pastes exactly what you said, cleaned of filler.\n\nYou say: \"um so the, the button is broken\"\n\nYou get: \"So the button is broken.\""
        case .professional:
            return "Polished prose ready to send as a text or email.\n\nYou say: \"tell mike cant make it tuesday, maybe thursday, ask him\"\n\nYou get: \"Hi Mike, I can't make Tuesday. Would Thursday work for you?\""
        case .agent:
            return "Turns a rambling task description into a brief for a coding agent.\n\nYou say: \"fix the auth thing where the token expires and it doesn't refresh, don't touch the session code\"\n\nYou get: Goal, Constraints, Done when, and Context sections, with no invented requirements."
        case .expand:
            return "Takes one short sentence and fills in the detail an AI needs.\n\nYou say: \"add rate limiting to the API\"\n\nYou get: the same request with edge cases, limits, and what done looks like spelled out. Anything it can't infer is listed as an open question instead of guessed."
        }
    }

    // Wire value sent to the polish proxy. `.raw` and `.ask` never hit it.
    var proxyMode: String? {
        switch self {
        case .summarize:    return "summarize"
        case .professional: return "professional"
        case .agent:        return "agent"
        case .expand:       return "expand"
        case .raw, .ask:    return nil
        }
    }

    // Config wire value for SELECTED_MODE (the remembered HUD pick). `.raw`
    // is stored as "normal" to match the DEFAULT_MODE vocabulary.
    var configValue: String {
        switch self {
        case .ask:          return "ask"
        case .summarize:    return "summarize"
        case .raw:          return "normal"
        case .professional: return "professional"
        case .agent:        return "agent"
        case .expand:       return "expand"
        }
    }

    static func fromConfig(_ s: String) -> DeliverMode {
        switch s {
        case "summarize":    return .summarize
        case "professional": return .professional
        case "normal":       return .raw
        case "agent":        return .agent
        case "expand":       return .expand
        default:             return .ask
        }
    }
}


// DEFAULT_MODE wire values, in the same order as the Settings popup titles.
// ⚠️ Deliberately NOT referenced from Config.load() — a global read during
// top-level init is what caused the V8.5 segfault. The parser keeps its own
// inline literal; keep the two lists in sync by hand.
let SETTINGS_MODES = ["summarize", "professional", "normal", "agent", "expand"]

// ===================== Settings window =====================
// Everything a customer needs to configure, in one place: their license, the
// key that starts dictation, how they want the writing to sound, language,
// microphone, plus their dictionary and snippets. Writing a value here edits
// ~/.dictation/config and restarts the daemon, so nothing needs a rebuild.
func writeConfigValue(_ key: String, _ value: String) {
    let path = CONFIG_PATH
    var lines = (try? String(contentsOfFile: path, encoding: .utf8))?
        .components(separatedBy: "\n") ?? []
    var replaced = false
    for i in lines.indices where lines[i].hasPrefix("\(key)=") {
        lines[i] = "\(key)=\(value)"
        replaced = true
    }
    if !replaced { lines.append("\(key)=\(value)") }
    try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    // This file holds LICENSE_KEY. The log and the history are already 0600;
    // the config was being left world-readable, and an atomic write recreates
    // the file, so the mode has to be reapplied every time.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var licenseField: NSTextField!
    private var styleField: NSTextField!
    private var hotkeyButton: NSButton!
    private var languagePopup: NSPopUpButton!
    private var modePopup: NSPopUpButton!
    private var micPopup: NSPopUpButton!
    private var whisperToggle: NSButton!
    private var statusLabel: NSTextField!

    private var hotkeyArmed = false          // second click puts it in capture mode
    private var pendingHotkey: UInt16 = 0
    private var captureMonitor: Any?

    private let languages = [("English", "en"), ("Detect automatically", "auto"),
                             ("Spanish", "es"), ("French", "fr"), ("German", "de"),
                             ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
                             ("Polish", "pl"), ("Hindi", "hi"), ("Japanese", "ja"),
                             ("Korean", "ko"), ("Chinese", "zh")]

    func show() {
        if window == nil { build() }
        pendingHotkey = cfg.hotkey
        refresh()
        // Hold the recording while settings are open. Without this, everything
        // said while configuring the app lands in the middle of the transcript.
        if dict.recording {
            dict.capturer.pauseCapture()
            ui.showPaused(true)
            log("· recording paused while settings are open")
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func label(_ text: String, _ y: CGFloat, bold: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: bold ? 13 : 12, weight: bold ? .semibold : .regular)
        l.textColor = bold ? .labelColor : .secondaryLabelColor
        l.frame = NSRect(x: 24, y: y, width: 200, height: 18)
        return l
    }

    private func build() {
        // The content is laid out on a document view TALLER than the window and
        // wrapped in a scroll view: every row stays reachable no matter how many
        // settings exist, which is how the Save row went missing pre-v8.16
        // (content ran to y = -58 in a fixed 560pt view with no scrolling).
        // v8.21: +184pt for the mode-keywords editor.
        let w: CGFloat = 520, h: CGFloat = 824, visibleH: CGFloat = 560
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: visibleH),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "NessoTalk Settings"
        win.isReleasedWhenClosed = false
        win.delegate = self
        let v = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        var y = h - 60
        let title = NSTextField(labelWithString: "NessoTalk")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.frame = NSRect(x: 24, y: y, width: 300, height: 26)
        v.addSubview(title)

        y -= 46
        v.addSubview(label("Your license key", y, bold: true))
        y -= 26
        licenseField = NSTextField(frame: NSRect(x: 24, y: y, width: w - 48, height: 24))
        licenseField.placeholderString = "Paste the key from nesso.tech"
        licenseField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        v.addSubview(licenseField)

        y -= 44
        v.addSubview(label("Key that starts and stops dictation", y, bold: true))
        y -= 28
        hotkeyButton = NSButton(title: "", target: self, action: #selector(hotkeyClicked))
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.frame = NSRect(x: 24, y: y, width: 220, height: 26)
        v.addSubview(hotkeyButton)
        let hint = NSTextField(labelWithString: "Click twice, then press the key you want.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 252, y: y + 4, width: 250, height: 18)
        v.addSubview(hint)

        y -= 44
        v.addSubview(label("How it should always write", y, bold: true))
        y -= 26
        styleField = NSTextField(frame: NSRect(x: 24, y: y, width: w - 48, height: 24))
        styleField.placeholderString = "for example: warm and direct, never stiff"
        v.addSubview(styleField)

        y -= 44
        v.addSubview(label("When you do not pick a mode", y, bold: true))
        y -= 28
        // Order must match SETTINGS_MODES below, and must cover every mode the
        // HUD offers or the two pickers disagree with each other.
        modePopup = NSPopUpButton(frame: NSRect(x: 24, y: y, width: 280, height: 26))
        modePopup.addItems(withTitles: ["Summarize for an AI tool",
                                        "Clean it up professionally",
                                        "Leave my words alone",
                                        "Write a brief for a coding agent",
                                        "Fill in the detail (AI Extend)"])
        v.addSubview(modePopup)

        y -= 44
        v.addSubview(label("Language", y, bold: true))
        y -= 28
        languagePopup = NSPopUpButton(frame: NSRect(x: 24, y: y, width: 220, height: 26))
        languagePopup.addItems(withTitles: languages.map { $0.0 })
        v.addSubview(languagePopup)

        y -= 44
        v.addSubview(label("Microphone", y, bold: true))
        y -= 28
        micPopup = NSPopUpButton(frame: NSRect(x: 24, y: y, width: w - 48, height: 26))
        micPopup.addItem(withTitle: "Built in microphone")
        for d in allInputDevices() where !d.builtIn { micPopup.addItem(withTitle: d.name) }
        v.addSubview(micPopup)

        y -= 40
        whisperToggle = NSButton(checkboxWithTitle: "Whisper mode, for dictating quietly in public",
                                 target: nil, action: nil)
        whisperToggle.frame = NSRect(x: 24, y: y, width: w - 48, height: 20)
        v.addSubview(whisperToggle)

        y -= 44
        let dict = NSButton(title: "Edit my dictionary", target: self, action: #selector(openDictionary))
        dict.bezelStyle = .rounded
        dict.frame = NSRect(x: 24, y: y, width: 170, height: 26)
        v.addSubview(dict)
        let snip = NSButton(title: "Edit my snippets", target: self, action: #selector(openSnippets))
        snip.bezelStyle = .rounded
        snip.frame = NSRect(x: 204, y: y, width: 160, height: 26)
        v.addSubview(snip)

        // v8.21: mode-keywords editor. The friendly face of ~/.dictation/
        // mode-rules: pick a section, type the phrase, click Add. The agent
        // sorter hot-loads the file on every dictation, so changes apply
        // INSTANTLY with no Save and no restart.
        y -= 48
        v.addSubview(label("Teach it your mode keywords", y, bold: true))
        y -= 20
        let kwHint = NSTextField(labelWithString: "Phrases you say that belong in a section of the AI Agent brief. Applied instantly.")
        kwHint.font = .systemFont(ofSize: 11)
        kwHint.textColor = .tertiaryLabelColor
        kwHint.frame = NSRect(x: 24, y: y, width: w - 48, height: 16)
        v.addSubview(kwHint)
        y -= 32
        kwSectionPopup = NSPopUpButton(frame: NSRect(x: 24, y: y, width: 126, height: 26))
        kwSectionPopup.addItems(withTitles: kwSections.map { $0.0 })
        v.addSubview(kwSectionPopup)
        kwPhraseField = NSTextField(frame: NSRect(x: 156, y: y + 1, width: 184, height: 24))
        kwPhraseField.placeholderString = "phrase you say"
        v.addSubview(kwPhraseField)
        kwWeightPopup = NSPopUpButton(frame: NSRect(x: 346, y: y, width: 84, height: 26))
        kwWeightPopup.addItems(withTitles: ["Gentle", "Normal", "Strong"])
        kwWeightPopup.selectItem(at: 1)
        v.addSubview(kwWeightPopup)
        let kwAdd = NSButton(title: "Add", target: self, action: #selector(kwAddClicked))
        kwAdd.bezelStyle = .rounded
        kwAdd.frame = NSRect(x: 436, y: y - 1, width: 60, height: 28)
        v.addSubview(kwAdd)
        y -= 84
        kwScroll = NSScrollView(frame: NSRect(x: 24, y: y, width: w - 48, height: 76))
        kwScroll.hasVerticalScroller = true
        kwScroll.borderType = .bezelBorder
        kwScroll.drawsBackground = false
        v.addSubview(kwScroll)

        y -= 44
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: y + 4, width: 300, height: 18)
        v.addSubview(statusLabel)
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: w - 124, y: y, width: 100, height: 28)
        v.addSubview(save)

        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: visibleH))
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.documentView = v
        // Open showing the TOP of the settings, not the bottom.
        sv.contentView.scroll(to: NSPoint(x: 0, y: h - visibleH))
        sv.reflectScrolledClipView(sv.contentView)
        win.contentView = sv
        window = win
    }

    // ── Mode-keywords editor (v8.21) ─────────────────────────────────────────
    private var kwSectionPopup: NSPopUpButton!
    private var kwPhraseField: NSTextField!
    private var kwWeightPopup: NSPopUpButton!
    private var kwScroll: NSScrollView!
    private let kwSections = [("Goal", "goal"), ("Constraints", "constraint"),
                              ("Done when", "done"), ("Context", "context")]
    static let modeRulesPath = NSHomeDirectory() + "/.dictation/mode-rules"

    private func loadCustomRules() -> [(String, String, Double)] {
        var out: [(String, String, Double)] = []
        guard let raw = try? String(contentsOfFile: Self.modeRulesPath, encoding: .utf8) else { return out }
        for line in raw.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let colon = l.firstIndex(of: ":") else { continue }
            let section = String(l[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard ["goal", "constraint", "done", "context"].contains(section) else { continue }
            var phrase = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var weight = 2.0
            if let eq = phrase.range(of: "=", options: .backwards) {
                if let d = Double(phrase[eq.upperBound...].trimmingCharacters(in: .whitespaces)) {
                    weight = d
                    phrase = String(phrase[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
            if !phrase.isEmpty { out.append((section, phrase, weight)) }
        }
        return out
    }

    private func saveCustomRules(_ rules: [(String, String, Double)]) {
        var text = "# Your mode keywords. One per line: section: phrase = weight\n"
        text += "# Sections: goal, constraint, done, context. Managed from Settings.\n"
        for (s, p, wgt) in rules { text += "\(s): \(p) = \(Int(wgt))\n" }
        try? text.write(toFile: Self.modeRulesPath, atomically: true, encoding: .utf8)
    }

    private func rebuildKeywordList() {
        guard let scroll = kwScroll else { return }
        let rules = loadCustomRules()
        let rowH: CGFloat = 24
        let docW = scroll.frame.width - 16
        let docH = max(scroll.frame.height - 4, CGFloat(rules.count) * rowH + 4)
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: docW, height: docH))
        if rules.isEmpty {
            let empty = NSTextField(labelWithString: "No custom keywords yet. Add one above.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            empty.frame = NSRect(x: 6, y: docH - 22, width: docW - 12, height: 16)
            doc.addSubview(empty)
        }
        for (i, r) in rules.enumerated() {
            let rowY = docH - CGFloat(i + 1) * rowH
            let name = kwSections.first { $0.1 == r.0 }?.0 ?? r.0
            let strength = r.2 >= 3 ? "strong" : r.2 <= 1 ? "gentle" : "normal"
            let l = NSTextField(labelWithString: "\(name) · \"\(r.1)\" (\(strength))")
            l.font = .systemFont(ofSize: 11)
            l.lineBreakMode = .byTruncatingTail
            l.frame = NSRect(x: 6, y: rowY + 4, width: docW - 92, height: 16)
            doc.addSubview(l)
            let rm = NSButton(title: "Remove", target: self, action: #selector(kwRemoveClicked(_:)))
            rm.bezelStyle = .inline
            rm.font = .systemFont(ofSize: 10)
            rm.tag = i
            rm.frame = NSRect(x: docW - 80, y: rowY + 2, width: 72, height: 18)
            doc.addSubview(rm)
        }
        scroll.documentView = doc
    }

    @objc private func kwAddClicked() {
        let phrase = kwPhraseField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty else { return }
        let section = kwSections[max(0, kwSectionPopup.indexOfSelectedItem)].1
        let weight = [1.0, 2.0, 3.0][max(0, kwWeightPopup.indexOfSelectedItem)]
        var rules = loadCustomRules()
        rules.removeAll { $0.1.lowercased() == phrase.lowercased() }
        rules.append((section, phrase, weight))
        saveCustomRules(rules)
        kwPhraseField.stringValue = ""
        rebuildKeywordList()
        log("· mode keyword added: \(section): \(phrase)")
    }

    @objc private func kwRemoveClicked(_ sender: NSButton) {
        var rules = loadCustomRules()
        guard sender.tag >= 0, sender.tag < rules.count else { return }
        let removed = rules.remove(at: sender.tag)
        saveCustomRules(rules)
        rebuildKeywordList()
        log("· mode keyword removed: \(removed.0): \(removed.1)")
    }

    private func refresh() {
        rebuildKeywordList()
        licenseField.stringValue = cfg.licenseKey
        styleField.stringValue = cfg.style
        hotkeyButton.title = triggerKey(forCode: pendingHotkey).name
        whisperToggle.state = cfg.whisperMode ? .on : .off
        modePopup.selectItem(at: SETTINGS_MODES.firstIndex(of: cfg.defaultMode) ?? 0)
        if let i = languages.firstIndex(where: { $0.1 == cfg.language }) {
            languagePopup.selectItem(at: i)
        }
        if cfg.inputDevice != "builtin", let idx = micPopup.itemTitles.firstIndex(of: cfg.inputDevice) {
            micPopup.selectItem(at: idx)
        } else {
            micPopup.selectItem(at: 0)
        }
        statusLabel.stringValue = licenseValid
            ? "Your license is active."
            : "No active license. Visit nesso.tech."
    }

    // First click arms it, second click listens for the key you press next.
    @objc private func hotkeyClicked() {
        if !hotkeyArmed {
            hotkeyArmed = true
            hotkeyButton.title = "Click once more to change"
            return
        }
        hotkeyButton.title = "Press any modifier key now"
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] ev in
            guard let self = self else { return ev }
            if TRIGGER_KEYS.contains(where: { $0.code == ev.keyCode }) {
                self.pendingHotkey = ev.keyCode
                self.hotkeyButton.title = triggerKey(forCode: ev.keyCode).name
                self.hotkeyArmed = false
                if let m = self.captureMonitor { NSEvent.removeMonitor(m) }
                self.captureMonitor = nil
            }
            return ev
        }
    }

    @objc private func openDictionary() {
        let path = LEARNED_PATH
        if !FileManager.default.fileExists(atPath: path) {
            try? "# One per line. Write Canonical|misheard,variants to fix a word.\n"
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func openSnippets() {
        NSWorkspace.shared.open(URL(fileURLWithPath: SNIPPETS_PATH))
    }

    @objc private func saveClicked() {
        writeConfigValue("LICENSE_KEY", licenseField.stringValue.trimmingCharacters(in: .whitespaces))
        writeConfigValue("STYLE", styleField.stringValue)
        writeConfigValue("HOTKEY", String(pendingHotkey))
        writeConfigValue("WHISPER_MODE", whisperToggle.state == .on ? "1" : "0")
        writeConfigValue("DEFAULT_MODE", SETTINGS_MODES[max(0, min(SETTINGS_MODES.count - 1, modePopup.indexOfSelectedItem))])
        writeConfigValue("LANGUAGE", languages[max(0, languagePopup.indexOfSelectedItem)].1)
        writeConfigValue("INPUT_DEVICE", micPopup.indexOfSelectedItem == 0 ? "builtin" : micPopup.titleOfSelectedItem ?? "builtin")
        statusLabel.stringValue = "Saved. Restarting NessoTalk."
        log("· settings saved from the settings window")
        // launchd brings it straight back with the new configuration.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.brady.ptt-dictate"]
            try? p.run()
        }
    }

    func windowWillClose(_ n: Notification) {
        if let m = captureMonitor { NSEvent.removeMonitor(m) }
        captureMonitor = nil
        hotkeyArmed = false
        // Pick the recording back up exactly where it left off.
        if dict.capturer.isPaused {
            dict.capturer.resumeCapture()
            ui.showPaused(false)
            log("· recording resumed after settings closed")
        }
    }
}

// v8.9: the ⓘ that actually works. A floating, non-activating card that spells
// out every mode with its before/after example, opened from the Mode menu's
// "What does each mode do?" item. Clicks never steal focus from the paste
// target (ChoicePanel recipe). While it is open the recording stays paused —
// reading about modes is not dictating.
final class ModeInfoPanel: NSObject {
    static let shared = ModeInfoPanel()
    private var panel: NSPanel?
    private var onClose: (() -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    func show(onClose: (() -> Void)?) {
        self.onClose = onClose
        if panel == nil { build() }
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - p.frame.width / 2, y: f.minY + 240,
                              width: p.frame.width, height: p.frame.height), display: true)
        }
        p.orderFrontRegardless()
    }

    @objc func done() {
        panel?.orderOut(nil)
        let cb = onClose
        onClose = nil
        cb?()
    }

    private func build() {
        let w: CGFloat = 620, h: CGFloat = 560, pad: CGFloat = 24
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.95).cgColor
        root.layer?.cornerRadius = 20
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        root.layer?.borderWidth = 1

        let title = NSTextField(labelWithString: "What each mode does")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white
        title.frame = NSRect(x: pad, y: h - 44, width: w - pad * 2, height: 22)
        root.addSubview(title)

        // Stacked mode blocks inside a scroll view, so the card never outgrows
        // a small screen. Heights are measured from the wrapped text.
        let textW = w - pad * 2 - 16
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: w - pad * 2, height: 10))
        var y: CGFloat = 4
        for m in DeliverMode.pickable + [DeliverMode.ask] {
            let name = NSTextField(labelWithString: m == .ask ? "Ask (nothing picked)" : m.label)
            name.font = .systemFont(ofSize: 13.5, weight: .semibold)
            name.textColor = .white
            name.frame = NSRect(x: 0, y: y, width: textW, height: 18)
            doc.addSubview(name)
            y += 22
            let body = NSTextField(wrappingLabelWithString: m.example)
            body.font = .systemFont(ofSize: 12.5, weight: .regular)
            body.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
            let bh = body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 10_000)).height ?? 60
            body.frame = NSRect(x: 0, y: y, width: textW, height: ceil(bh))
            doc.addSubview(body)
            y += ceil(bh) + 18
        }
        doc.frame = NSRect(x: 0, y: 0, width: w - pad * 2, height: y)

        let scroll = NSScrollView(frame: NSRect(x: pad, y: 64, width: w - pad * 2, height: h - 44 - 22 - 64))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = doc
        root.addSubview(scroll)

        let btn = ClickThroughButton(title: "Done", target: self, action: #selector(done))
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 14
        btn.frame = NSRect(x: (w - 120) / 2, y: 14, width: 120, height: 34)
        btn.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        btn.attributedTitle = NSAttributedString(string: "Done", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: center,
        ])
        root.addSubview(btn)

        p.contentView = root
        panel = p
    }
}

// v8.19: explicit resize handles. A borderless panel gets NO system resize
// edges (macOS only draws them on framed windows — the v8.18 .resizable flag
// alone did nothing, which is exactly what Brady hit), so the pill carries
// its own: invisible strips on all four edges plus corner zones that track
// the drag themselves and resize the window live, terminal-style.
// mouseDownCanMoveWindow=false keeps them from fighting the drag-to-move
// background; acceptsFirstMouse makes the first click land while another
// app keeps focus (same rule as ClickThroughButton).
final class ResizeEdgeView: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left   = Edges(rawValue: 1)
        static let right  = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top    = Edges(rawValue: 8)
    }
    let edges: Edges
    init(edges: Edges) { self.edges = edges; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let horiz = !edges.intersection([.left, .right]).isEmpty
        let vert  = !edges.intersection([.top, .bottom]).isEmpty
        addCursorRect(bounds, cursor: horiz && vert ? .crosshair
                                    : horiz ? .resizeLeftRight : .resizeUpDown)
    }

    // Event-driven on purpose — NO tracking loop. A nextEvent loop blocks the
    // main thread until mouse-up arrives, and a missed up-event (it happens)
    // would starve the caption timer, the HUD Stop button, AND the Right-⌘
    // global monitor: the exact "cannot stop a recording" failure the V8.7
    // rebuild swore off. With plain overrides, each drag step is just an
    // event; a missed mouse-up merely ends the gesture.
    private var dragStartFrame: NSRect?
    private var dragStartMouse: NSPoint?

    override func mouseDown(with event: NSEvent) {
        dragStartFrame = window?.frame
        dragStartMouse = NSEvent.mouseLocation
        log("· resize grip grabbed (\(edges.rawValue))")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let f0 = dragStartFrame, let m0 = dragStartMouse else { return }
        let minS = win.minSize
        let now = NSEvent.mouseLocation
        let dx = now.x - m0.x, dy = now.y - m0.y
        var f = f0
        if edges.contains(.right) { f.size.width = max(minS.width, f0.width + dx) }
        if edges.contains(.left) {
            let nw = max(minS.width, f0.width - dx)
            f.origin.x = f0.maxX - nw; f.size.width = nw
        }
        if edges.contains(.top) { f.size.height = max(minS.height, f0.height + dy) }
        if edges.contains(.bottom) {
            let nh = max(minS.height, f0.height - dy)
            f.origin.y = f0.maxY - nh; f.size.height = nh
        }
        win.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let win = window, dragStartFrame != nil else { return }
        dragStartFrame = nil
        dragStartMouse = nil
        log("· pill resized to \(Int(win.frame.width))×\(Int(win.frame.height))")
    }
}

// ===================== UI: menu bar + live-caption HUD =====================
final class UIController: NSObject, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var panel: NSPanel?
    var captionField: NSTextField?
    var elapsedField: NSTextField?
    var waveform: WaveformView?
    var modeButtons: [DeliverMode: NSButton] = [:]
    var modeMenuButton: NSButton?
    var captionScroll: NSScrollView?
    // v8.18: the pill is draggable and resizable like a terminal window.
    // These hold the top-row buttons so layoutHUD() can re-derive every frame
    // from the current panel size; customHUDFrame remembers where the user
    // put it (and how big) for the rest of the session — a daemon restart
    // goes back to the default size and bottom-center spot.
    var finishButton: NSButton?
    var stopButton: NSButton?
    var cancelButton: NSButton?
    var settingsButton: NSButton?
    var customHUDFrame: NSRect?
    var suppressFrameTracking = false
    var resizeEdges: [ResizeEdgeView] = []
    var selectedMode: DeliverMode = .ask     // main-thread only; captured at stop
    var modePickedThisRecording = false      // a HUD menu pick this recording; cleared on start
    var uiTimer: Timer?
    var recordStart: Date?
    var pausedAt: Date?
    var busyCount = 0
    var toggleMenuItem: NSMenuItem?
    // v8.9: true while the pause on the capturer belongs to the mode menu or
    // the mode explainer (as opposed to the Settings window, which manages its
    // own pause via windowWillClose).
    var modePauseActive = false

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🎙"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start Dictation (Right ⌘)", action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        toggleMenuItem = toggle
        let cancel = NSMenuItem(title: "Cancel Recording (discard)", action: #selector(menuCancel), keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let logItem = NSMenuItem(title: "Open Log", action: #selector(menuLog), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)
        let quit = NSMenuItem(title: "Quit ptt-dictate", action: #selector(menuQuit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item

        // HUD panel: borderless dark pill, bottom-center. Non-activating and
        // becomesKeyOnlyIfNeeded so the mode buttons are clickable WITHOUT the
        // click ever stealing focus from the app being dictated into (the same
        // proven ChoicePanel recipe).
        let w: CGFloat = 640, h: CGFloat = 196
        // v8.18: .resizable on a borderless panel enables edge/corner drag
        // resizing (up to any size, including the whole screen), and
        // isMovableByWindowBackground makes every non-control area a drag
        // handle. Minimum keeps the guaranteed STOP/✕ exits reachable; below
        // ~2 caption lines the transcript simply clips, by design.
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel, .resizable],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.minSize = NSSize(width: 420, height: 150)
        p.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.92).cgColor
        root.layer?.cornerRadius = 24
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        root.layer?.borderWidth = 1

        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        elapsed.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        elapsed.frame = NSRect(x: 20, y: h - 34, width: 96, height: 18)
        root.addSubview(elapsed)
        elapsedField = elapsed

        // The waveform IS the recording indicator (replaces the old red dot).
        let wfW: CGFloat = 200, wfH: CGFloat = 30
        let wf = WaveformView(frame: NSRect(x: (w - wfW) / 2 - 80, y: h - 42, width: wfW, height: wfH))
        root.addSubview(wf)
        waveform = wf

        // STOP and CANCEL live on the panel itself, and that is the whole point.
        // The Right-⌘ hotkey rides NSEvent's GLOBAL monitor, which macOS silently
        // starves whenever any app holds Secure Input (Terminal's "Secure Keyboard
        // Entry" does exactly this), and which the chord veto can also swallow.
        // A click on our own window goes through the app's own event path and
        // cannot be starved or vetoed by anything. These buttons are the
        // guaranteed way out of a recording.
        //
        // v8.8: FINISH sits directly next to STOP. Stop keeps today's behavior
        // (stop, then deliver through the selected mode — the rewrite may take
        // a few seconds). Finish is push-to-live: stop and paste IMMEDIATELY
        // with whatever is already prepared — the pre-run rewrite if it's done,
        // otherwise your words exactly as spoken. It never waits on the AI.
        let finishBtn = makeActionButton("⚡ Finish", x: w - 268, y: h - 44, width: 92, height: 32,
                                         action: #selector(hudFinish), accent: false,
                                         color: NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.28, alpha: 0.95))
        finishBtn.toolTip = "Push to live: stop and paste instantly — the finished rewrite if it's ready, otherwise exactly what you said. Never waits."
        root.addSubview(finishBtn)
        finishButton = finishBtn

        let stopBtn = makeActionButton("Stop", x: w - 168, y: h - 44, width: 92, height: 32,
                                       action: #selector(hudStop), accent: true)
        stopBtn.toolTip = "Stop and deliver in the selected mode. Always works, even when the hotkey does not."
        root.addSubview(stopBtn)
        stopButton = stopBtn

        let cancelBtn = makeActionButton("✕", x: w - 64, y: h - 44, width: 44, height: 32,
                                         action: #selector(hudCancel), accent: false)
        cancelBtn.toolTip = "Discard this recording. Always works, even when Esc does not."
        root.addSubview(cancelBtn)
        cancelButton = cancelBtn

        // Caption area, scrollable so long dictations can be read back.
        let scrollFrame = NSRect(x: 16, y: 68, width: w - 32, height: 82)
        let scroller = NSScrollView(frame: scrollFrame)
        scroller.drawsBackground = false
        scroller.hasVerticalScroller = true
        scroller.autohidesScrollers = false
        scroller.scrollerStyle = .overlay
        scroller.borderType = .noBorder

        let caption = NSTextField(wrappingLabelWithString: "Listening…")
        caption.font = .systemFont(ofSize: 16, weight: .medium)
        caption.textColor = .white
        caption.drawsBackground = false
        caption.isBezeled = false
        caption.isEditable = false
        caption.isSelectable = true
        caption.frame = NSRect(x: 0, y: 0, width: scrollFrame.width - 16, height: scrollFrame.height)
        scroller.documentView = caption
        root.addSubview(scroller)
        captionField = caption
        captionScroll = scroller

        // Two equal, large, obvious buttons. Settings pauses the recording;
        // Mode opens the five-way picker with a hover example on each.
        let pad: CGFloat = 18, gap: CGFloat = 12, btnH: CGFloat = 42
        let btnW = (w - pad * 2 - gap) / 2
        let setBtn = makeActionButton("⚙  Settings", x: pad, y: 14, width: btnW, height: btnH,
                                      action: #selector(modeSettings), accent: false)
        setBtn.toolTip = "Opens settings. Your recording pauses while it is open and resumes when you close it."
        let modeBtn = makeActionButton("◈  Mode", x: pad + btnW + gap, y: 14, width: btnW, height: btnH,
                                       action: #selector(hudPickMode), accent: false)
        modeBtn.toolTip = "Choose how this dictation is delivered."
        root.addSubview(setBtn); root.addSubview(modeBtn)
        settingsButton = setBtn
        modeMenuButton = modeBtn
        // v8.8: restore the remembered mode, so the app reopens already
        // running in whatever mode was active last time it was used.
        selectedMode = DeliverMode.fromConfig(cfg.selectedMode)
        if selectedMode != .ask { log("· mode restored: \(selectedMode.label)") }
        refreshModeButton()

        // Resize handles go in LAST so they sit above everything else and
        // always win the click at the pill's edges.
        let edgeSets: [ResizeEdgeView.Edges] = [
            [.left], [.right], [.top], [.bottom],
            [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom],
        ]
        for set in edgeSets {
            let v = ResizeEdgeView(edges: set)
            root.addSubview(v)
            resizeEdges.append(v)
        }

        p.contentView = root
        panel = p
        layoutHUD()

        // One persistent ticker drives the elapsed readout, the pulsing dot,
        // and the menu-bar timer. Cheap, and far fewer states than start/stop timers.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common: keeps ticking while the status menu is open
        uiTimer = t
    }

    func tick() {
        guard let start = recordStart else { return }
        // Paused (settings open): freeze the readout at the pause moment and
        // leave the menu-bar ⏸ alone. recordStart is rewound on resume, so the
        // clock picks up exactly where it froze — matching the captured audio.
        if let p = pausedAt {
            let s = max(0, Int(p.timeIntervalSince(start)))
            elapsedField?.stringValue = String(format: "%d:%02d", s / 60, s % 60)
            return
        }
        let s = Int(Date().timeIntervalSince(start))
        let t = String(format: "%d:%02d", s / 60, s % 60)
        elapsedField?.stringValue = t
        statusItem?.button?.title = "🔴 \(t)"
    }

    func recordingStarted() {
        recordStart = Date()
        modePickedThisRecording = false
        statusItem?.button?.title = "🔴 0:00"
        toggleMenuItem?.title = "Stop & Transcribe (Right ⌘)"
        // The pill is the ONLY guaranteed way out of a recording: Stop and Cancel
        // are clicks on our own panel, which macOS cannot starve the way it
        // starves the global key monitor under Secure Input. So the panel must
        // appear for EVERY recording, unconditionally. Live captions are a
        // decoration on top of it and are allowed to be unavailable — gating the
        // whole HUD on the caption model is what left every customer with no
        // Stop button at all when CAPTION_MODEL pointed somewhere they had no file.
        let captionsLive = cfg.liveCaptions && dict.captions.modelAvailable
        captionField?.stringValue = captionsLive ? "Listening…" : "Recording. Tap Right ⌘ or press Stop when you are done."
        elapsedField?.stringValue = "0:00"
        // v8.8: the mode is sticky. Whatever was last picked stays active
        // across recordings AND restarts (SELECTED_MODE in the config) — no
        // more re-picking it every dictation.
        refreshModeButton()
        // HUD goes on the screen the user is actually on (the one under the
        // mouse) — NSScreen.main is just the primary display for an accessory app.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let p = panel {
            // v8.18: if the user dragged or resized the pill this session,
            // honor that spot and size; otherwise the default pill sits
            // bottom-center of the screen the mouse is on, exactly as set up.
            suppressFrameTracking = true
            if let custom = customHUDFrame {
                p.setFrame(custom, display: true)
            } else if let f = screen?.visibleFrame {
                p.setFrame(NSRect(x: f.midX - 320, y: f.minY + 28,
                                  width: 640, height: 196), display: true)
            }
            suppressFrameTracking = false
            layoutHUD()
            p.orderFrontRegardless()
            waveform?.start()
            // Position log: makes "where did the pill go" debuggable and gives
            // the resize drag test exact screen coordinates.
            log("· pill frame \(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))×\(Int(p.frame.height))")
        }
    }

    func recordingStopped() {
        recordStart = nil
        waveform?.stop()
        panel?.orderOut(nil)
        toggleMenuItem?.title = "Start Dictation (Right ⌘)"
        refreshIdleOrBusy()
    }

    // Settings pause. The elapsed clock is rewound by however long the pause
    // lasted, so the readout keeps matching the audio that actually got captured.
    func showPaused(_ on: Bool, message: String = "Paused while settings are open.") {
        if on {
            pausedAt = Date()
            waveform?.stop()
            captionField?.stringValue = message
            statusItem?.button?.title = "⏸"
        } else {
            if let p = pausedAt, let s = recordStart {
                recordStart = s.addingTimeInterval(Date().timeIntervalSince(p))
            }
            pausedAt = nil
            if recordStart != nil {
                waveform?.start()
                captionField?.stringValue = "Listening…"
                tick()
            }
        }
    }

    func setBusy(_ delta: Int) {
        busyCount = max(0, busyCount + delta)
        refreshIdleOrBusy()
    }

    func refreshIdleOrBusy() {
        guard recordStart == nil else { return }   // recording display wins
        statusItem?.button?.title = busyCount > 0 ? "⏳" : "🎙"
    }

    func setLevel(_ l: Float) { waveform?.setLevel(l) }

    // ClickThroughButton keeps the click from stealing focus from the app being
    // dictated into, which is why these are safe to press mid-recording.
    private func makeActionButton(_ title: String, x: CGFloat, y: CGFloat,
                                  width: CGFloat, height: CGFloat,
                                  action: Selector, accent: Bool,
                                  color: NSColor? = nil) -> NSButton {
        let b = ClickThroughButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = min(14, height / 2)
        b.frame = NSRect(x: x, y: y, width: width, height: height)
        b.layer?.backgroundColor = (color ?? (accent
            ? NSColor(calibratedRed: 0.85, green: 0.22, blue: 0.20, alpha: 0.95)
            : NSColor(calibratedWhite: 1, alpha: 0.14))).cgColor
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: height >= 40 ? 15 : 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: center,
        ])
        return b
    }

    func refreshModeButton() {
        guard let b = modeMenuButton else { return }
        let name = selectedMode == .ask ? "Mode" : selectedMode.label
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        b.attributedTitle = NSAttributedString(string: "◈  \(name)", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: center,
        ])
        b.layer?.backgroundColor = NSColor(calibratedWhite: 1,
                                           alpha: selectedMode == .ask ? 0.14 : 0.30).cgColor
    }

    // The five modes. Hover tooltips still carry each example, but the real
    // affordance is the explainer item at the bottom — an ⓘ you can click
    // (v8.9: the ⓘ glyph on every row looked clickable and wasn't).
    @objc func hudPickMode() {
        let menu = NSMenu()
        for m in DeliverMode.pickable {
            let item = NSMenuItem(title: m.label, action: #selector(hudModeChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.label
            item.toolTip = m.example
            item.state = (m == selectedMode) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Ask me after I stop", action: #selector(hudModeChosen(_:)), keyEquivalent: "")
        clear.target = self
        clear.representedObject = DeliverMode.ask.label
        clear.toolTip = DeliverMode.ask.example
        clear.state = (selectedMode == .ask) ? .on : .off
        menu.addItem(clear)
        menu.addItem(.separator())
        let info = NSMenuItem(title: "ⓘ What does each mode do?", action: #selector(hudModeInfo), keyEquivalent: "")
        info.target = self
        menu.addItem(info)

        // v8.9: reading the mode list is not dictating. Hold the recording
        // while the menu is up — same mechanism as Settings — and resume the
        // moment it closes, unless the explainer took over (it resumes on Done).
        if dict.recording && !dict.capturer.isPaused {
            dict.capturer.pauseCapture()
            modePauseActive = true
            showPaused(true, message: "Paused while you pick a mode.")
            log("· recording paused while the mode menu is open")
        }
        if let b = modeMenuButton {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: b.frame.height + 6), in: b)
        }
        // The clicked item's action can be delivered on the main queue after
        // popUp returns, so the resume decision waits behind it. If the
        // explainer is (or is about to be) up, its Done button owns the resume.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.modePauseActive else { return }
            if !ModeInfoPanel.shared.isVisible { self.endModePause() }
        }
    }

    @objc func hudModeInfo() {
        // Keep (or take back) the pause while the explainer is up. If the
        // deferred resume in hudPickMode already fired, this re-pauses.
        if dict.recording && !dict.capturer.isPaused {
            dict.capturer.pauseCapture()
            modePauseActive = true
            showPaused(true, message: "Paused while you read about the modes.")
        }
        log("· mode explainer opened")
        ModeInfoPanel.shared.show(onClose: { [weak self] in
            guard let self = self, self.modePauseActive else { return }
            self.endModePause()
        })
    }

    // Ends a pause that the mode menu/explainer started. Never touches a pause
    // owned by the Settings window (modePauseActive is false there).
    func endModePause() {
        modePauseActive = false
        guard dict.capturer.isPaused else { return }
        dict.capturer.resumeCapture()
        showPaused(false)
        log("· recording resumed")
    }

    @objc func hudModeChosen(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String,
              let m = DeliverMode.allCases.first(where: { $0.label == label }) else { return }
        selectedMode = m
        refreshModeButton()
        // Persist the pick right away — this is what makes it survive a full
        // quit/reopen. Writing the config does NOT restart the daemon; the
        // in-memory selection above is already live for this session.
        writeConfigValue("SELECTED_MODE", m.configValue)
        modePickedThisRecording = true
        // Teach the per-app habit — the learner only ever reads explicit picks.
        if m != .ask {
            let app = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "").lowercased()
            recordModePick(app: app, mode: m.configValue)
        }
        log("· HUD mode: \(selectedMode.label) (remembered)")
    }

    // Guaranteed exits. These do not touch the global event monitor, so Secure
    // Input and the chord veto cannot reach them.
    @objc func hudStop() {
        log("· stop pressed on HUD")
        if dict.recording { dict.toggle() }
    }

    @objc func hudFinish() {
        log("· finish pressed on HUD — push to live")
        if dict.recording { dict.finishInstantly() }
    }

    @objc func hudCancel() {
        log("· cancel pressed on HUD")
        if dict.recording { dict.cancelRecording() }
    }

    @objc func modeSettings() { SettingsWindow.shared.show() }

    // v8.18: single source of truth for the pill's layout. Every frame is
    // derived from the CURRENT panel size, so resizing reflows everything:
    // the caption area absorbs all extra room (bigger = more transcript),
    // shrinking clips the transcript first, and the guaranteed exits
    // (STOP / ✕) plus the bottom controls stay pinned and reachable at
    // every size. The waveform gives way when the top bar gets tight.
    func layoutHUD() {
        guard let p = panel, let root = p.contentView else { return }
        let w = root.bounds.width, h = root.bounds.height

        elapsedField?.frame = NSRect(x: 20, y: h - 34, width: 96, height: 18)
        finishButton?.frame = NSRect(x: w - 268, y: h - 44, width: 92, height: 32)
        stopButton?.frame   = NSRect(x: w - 168, y: h - 44, width: 92, height: 32)
        cancelButton?.frame = NSRect(x: w - 64,  y: h - 44, width: 44, height: 32)

        // Waveform lives between the elapsed readout and the Finish button;
        // it shrinks with the pill and hides entirely when there is no room.
        let wfLeft: CGFloat = 124, wfRight = w - 276
        let avail = wfRight - wfLeft
        if avail >= 60, let wf = waveform {
            let wfW = min(200, avail)
            wf.isHidden = false
            wf.frame = NSRect(x: wfLeft + (avail - wfW) / 2, y: h - 42, width: wfW, height: 30)
        } else {
            waveform?.isHidden = true
        }

        captionScroll?.frame = NSRect(x: 16, y: 68, width: w - 32, height: max(0, h - 114))
        let pad: CGFloat = 18, gap: CGFloat = 12
        let btnW = (w - pad * 2 - gap) / 2
        settingsButton?.frame = NSRect(x: pad, y: 14, width: btnW, height: 42)
        modeMenuButton?.frame = NSRect(x: pad + btnW + gap, y: 14, width: btnW, height: 42)

        // Resize handles hug the current edges: 8pt strips, 14pt corners.
        let g: CGFloat = 8, c: CGFloat = 14
        for v in resizeEdges {
            switch v.edges {
            case [.left]:           v.frame = NSRect(x: 0, y: c, width: g, height: max(0, h - 2 * c))
            case [.right]:          v.frame = NSRect(x: w - g, y: c, width: g, height: max(0, h - 2 * c))
            case [.top]:            v.frame = NSRect(x: c, y: h - g, width: max(0, w - 2 * c), height: g)
            case [.bottom]:         v.frame = NSRect(x: c, y: 0, width: max(0, w - 2 * c), height: g)
            case [.left, .top]:     v.frame = NSRect(x: 0, y: h - c, width: c, height: c)
            case [.right, .top]:    v.frame = NSRect(x: w - c, y: h - c, width: c, height: c)
            case [.left, .bottom]:  v.frame = NSRect(x: 0, y: 0, width: c, height: c)
            case [.right, .bottom]: v.frame = NSRect(x: w - c, y: 0, width: c, height: c)
            default: break
            }
        }
        for v in resizeEdges { panel?.invalidateCursorRects(for: v) }

        // Re-wrap the transcript to the new width right away.
        if let f = captionField { setCaption(f.stringValue) }
    }

    func windowDidResize(_ n: Notification) {
        guard (n.object as? NSPanel) === panel else { return }
        layoutHUD()
        if !suppressFrameTracking, panel?.isVisible == true { customHUDFrame = panel?.frame }
    }

    func windowDidMove(_ n: Notification) {
        guard (n.object as? NSPanel) === panel, !suppressFrameTracking,
              panel?.isVisible == true else { return }
        customHUDFrame = panel?.frame
    }

    func setCaption(_ text: String) {
        guard let field = captionField, let scroll = captionScroll else { return }
        // The caption now lives in a scroll view, so instead of clipping to two
        // lines we keep a readable backlog and grow the field to fit it. The
        // newest words stay visible because we pin the scroll to the bottom;
        // everything earlier is still there if the user scrolls up.
        let tail = String(text.suffix(1200))
        field.stringValue = tail

        let width = scroll.contentView.bounds.width - 4
        let measure = NSTextFieldCell(textCell: tail)
        measure.font = field.font
        measure.wraps = true
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let needed = max(scroll.contentView.bounds.height, measure.cellSize(forBounds: bounds).height + 6)
        field.frame = NSRect(x: 0, y: 0, width: width, height: needed)

        // Flipped document view: y=0 is the top, so the bottom is maxY.
        let bottom = max(0, needed - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc func menuToggle() { dict.toggle() }
    @objc func menuCancel() { dict.cancelRecording() }
    @objc func menuSettings() { SettingsWindow.shared.show() }
    @objc func menuLog() { NSWorkspace.shared.open(URL(fileURLWithPath: LOG)) }
    @objc func menuQuit() {
        // Under launchd KeepAlive, NSApp.terminate just respawns the daemon —
        // bootout actually stops the agent (launchd sends us SIGTERM).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/com.brady.ptt-dictate"]
        try? p.run()
        // Fallback for running outside launchd (manual debug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
}

// ===================== Live captions (rolling transcript) =====================
// TV-caption behavior: the HUD shows ONE continuous transcript that only ever
// appends — words never vanish or rewrite once spoken; older text scrolls out
// of the 2-line box (setCaption trims from the front). Mechanism: text is split
// into COMMITTED (immutable) + LIVE tail. Every captionInterval seconds the
// small model re-decodes only [committedByte, now]; once that live span exceeds
// captionWindow seconds, everything up to a detected pause is decoded one last
// time and locked into `committed`, so at most the trailing few seconds ever
// jitter. This is a preview only — the final paste comes from the full-quality
// chunk cache / whole-file decode.
final class CaptionEngine {
    // ALL state is confined to this serial queue; start()/stop() only enqueue.
    // A generation token (not `timer != nil`) keeps a pass that straddles a
    // stop/start from painting the PREVIOUS session's words into the new HUD.
    private let queue = DispatchQueue(label: "ptt.captions", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var wavPath = ""
    private var dataOffset: UInt64?
    private var committed = ""              // locked words — they never change
    private var committedByte: UInt64 = 0   // where the live tail starts (rel. to data chunk)
    // pid-unique: a CLI sim and the live daemon must NEVER share these — shared
    // fixed paths let a test's decode text bleed into the live HUD and vice versa.
    private let tmpWav = "/tmp/ptt_caption_\(getpid()).wav"
    private let tmpTxt = "/tmp/ptt_caption_\(getpid())"

    // Injected so --caption-sim can print HUD frames without an NSApp/HUD.
    var display: (String) -> Void = { t in DispatchQueue.main.async { ui.setCaption(t) } }

    var modelAvailable: Bool { FileManager.default.fileExists(atPath: cfg.captionModel) }

    func start(wav: String) {
        guard cfg.liveCaptions, modelAvailable else { return }
        queue.async {
            self.generation += 1
            let gen = self.generation
            self.reset(wav: wav)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + cfg.captionInterval, repeating: cfg.captionInterval)
            t.setEventHandler { [weak self] in self?.pass(gen: gen) }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async {
            self.generation += 1
            self.timer?.cancel()
            self.timer = nil
        }
    }

    // Test hooks for --caption-sim: drive passes without a timer/mic.
    func simStart(wav: String) { queue.sync { reset(wav: wav) } }
    func simPass() { queue.sync { pass(gen: generation) } }

    private func reset(wav: String) {
        wavPath = wav
        dataOffset = nil
        committed = ""
        committedByte = 0
        timer?.cancel(); timer = nil
    }

    // Decode [from, to) of the in-flight WAV with the caption model; returns
    // cleaned text ("" is a valid result for silence), nil on decode failure.
    private func decodeRange(_ fh: FileHandle, off: UInt64, from: UInt64, to: UInt64) -> String? {
        fh.seek(toFileOffset: off + from)
        let pcm = fh.readData(ofLength: Int(to - from))
        writeWav16kMono(pcm, to: tmpWav)
        try? FileManager.default.removeItem(atPath: tmpTxt + ".txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: WHISPER)
        p.arguments = ["-m", cfg.captionModel, "-f", tmpWav, "-l", "en",
                       "-nt", "-otxt", "-of", tmpTxt, "-bs", "1", "-bo", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Watchdog: one hung decode must not wedge this serial queue forever —
        // that would kill captions for every future session until restart.
        DispatchQueue.global().asyncAfter(deadline: .now() + max(10, cfg.captionInterval * 4)) { [weak p] in
            if let p = p, p.isRunning {
                p.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
        p.waitUntilExit()
        guard var text = try? String(contentsOfFile: tmpTxt + ".txt", encoding: .utf8) else { return nil }
        text = regexReplace(text, "\\[[A-Z_ ]+\\]", " ")
        text = regexReplace(text, "\\([^)]*\\)", " ")
        return regexReplace(text, "\\s+", " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pass(gen: Int) {
        guard gen == generation else { return }
        if dataOffset == nil { dataOffset = findWavDataOffset(wavPath) ?? 4096 }
        guard let off = dataOffset,
              let fh = FileHandle(forReadingAtPath: wavPath) else { return }
        defer { fh.closeFile() }
        let size = fh.seekToEndOfFile()
        guard size > off else { return }
        // Sample alignment must hold for the read START relative to the data
        // chunk — align availability, not length (a torn mid-write size can be odd).
        let usable = (size - off) & ~1
        guard usable > committedByte + 32000 else { return }   // ≥1s of new audio
        let span = usable - committedByte
        let commitSpan = UInt64(max(6.0, min(cfg.captionWindow, 10.0)) * 32000)
        // Commit ONLY at a detected pause — a mid-word cut would freeze a
        // mangled seam into the committed line. If he talks straight through,
        // let the live span grow to 2× before a last-resort hard cut 2s back.
        var cutB: UInt64?
        if span > commitSpan {
            cutB = quietCutPoint(fh: fh, dataOff: off, from: committedByte, to: usable,
                                 lookback: min(span, UInt64(6 * 32000)))
            if cutB == nil, span > commitSpan * 2 {
                cutB = max(committedByte + 32000, (usable - UInt64(2 * 32000)) & ~1)
            }
        }
        if let cut = cutB {
            guard let head = decodeRange(fh, off: off, from: committedByte, to: cut),
                  gen == generation else { return }
            if !head.isEmpty { committed += (committed.isEmpty ? "" : " ") + head }
            committedByte = cut
            // Fresh live tail in the same frame — the HUD must never shrink at
            // a commit (words visibly vanishing was the old design's sin).
            var tail = ""
            if usable > cut + 19200 {                          // ≥0.6s after the cut
                tail = decodeRange(fh, off: off, from: cut, to: usable) ?? ""
            }
            guard gen == generation else { return }
            let full = committed + (tail.isEmpty ? "" : (committed.isEmpty ? "" : " ") + tail)
            if !full.isEmpty { display(full) }
        } else {
            guard let txt = decodeRange(fh, off: off, from: committedByte, to: usable),
                  gen == generation else { return }
            let full = committed + (txt.isEmpty ? "" : (committed.isEmpty ? "" : " ") + txt)
            if !full.isEmpty { display(full) }
        }
    }
}

// ===================== Transcription pipeline (whisper-cli) =====================
// Free functions: they touch no daemon state, and the rolling-chunk engine and
// the CLI test modes need them without constructing a Dictation.

// Condition the captured clip before decoding: high-pass (kill rumble/handling),
// FFT denoise (afftdn, adaptive noise tracking), then a dynamic normalizer that
// lifts quiet/ducked words to a consistent level. This is what closes most of
// the gap to Wispr-class tools on noisy or on-call audio. Call mode uses a
// stronger chain because the OS echo-canceller ducks the mic harder mid-call.
// Returns a temp wav to decode, or nil to fall back to the raw clip.
func preprocessAudio(_ wavPath: String, duration: Double) -> String? {
    guard cfg.preprocess, FileManager.default.fileExists(atPath: FFMPEG) else { return nil }
    let out = wavPath + ".pp.wav"
    try? FileManager.default.removeItem(atPath: out)
    // dynaudnorm g (gauss window) must be ODD. Call chain: harder denoise + more
    // gain + faster reaction so ducked words clear whisper's decode floor.
    // Whisper-mode chain: speechnorm's expansion lifts whisper-level speech to
    // normal amplitude far more aggressively than dynaudnorm ever should.
    // ffmpeg 8 tightened afftdn's nf range to [-80, -20]; the old -18 whisper
    // value now errors out (exit 222) and silently cost EVERY whisper-mode
    // dictation its gain chain from ~08-06 until 08-09. -20 is the closest
    // valid (gentlest) floor. Keep every nf here <= -20.
    let chain = cfg.whisperMode
        ? "highpass=f=80,afftdn=nf=-20:tn=1,speechnorm=e=25:r=0.0002:l=1"
        : cfg.callMode
        ? "highpass=f=80,afftdn=nf=-20:tn=1,dynaudnorm=f=150:g=21:p=0.95:m=20"
        : "highpass=f=70,afftdn=nf=-25:tn=1,dynaudnorm=f=200:g=15:p=0.9:m=10"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: FFMPEG)
    p.arguments = ["-hide_banner", "-loglevel", "error", "-y",
                   "-i", wavPath, "-af", chain,
                   "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("!! ffmpeg preprocess error: \(error)"); return nil }
    // Audio filtering runs many× realtime; cap it so a wedge can't stall a decode.
    let timeout = max(30.0, duration * 0.5 + 30)
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
        if let p = p, p.isRunning { p.terminate() }
    }
    p.waitUntilExit()
    let okBytes = (try? FileManager.default.attributesOfItem(atPath: out)[.size] as? Int) ?? 0
    guard p.terminationStatus == 0, okBytes > 1024 else {
        log("⚠️ preprocess failed (status \(p.terminationStatus), \(okBytes)B) — decoding raw clip")
        try? FileManager.default.removeItem(atPath: out)
        return nil
    }
    return out
}

// Resident-server decode (launchd agent com.brady.ptt-whisper-server, port
// 8977): the model stays loaded between dictations, skipping the 1-2s load
// every CLI spawn pays — short dictations paste near-instantly. The server
// carries the same decode params as launch flags; VAD toggle and vocab prompt
// ride each request. Returns nil on ANY trouble (down, error body, bad JSON)
// so the caller falls back to the CLI path; {"text":""} is an honest
// VAD-ate-everything empty and comes back as "".
// NOTE: the server's VAD threshold is fixed at LAUNCH (-vt in its plist) —
// whisper-server 1.8.6 ignores per-request vad_threshold. After tuning
// VAD_THRESHOLD in the config, run `ptt server sync` to regenerate the plist.
func runWhisperViaServer(wav: String, timeout: Double) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var args = ["-s", "--max-time", String(Int(timeout)),
                "http://127.0.0.1:8977/inference",
                "-F", "file=@\(wav)",
                "-F", "response_format=json",
                "-F", "language=\(cfg.language)",
                "-F", "prompt=\(effectivePrompt())"]
    if FileManager.default.fileExists(atPath: VAD_MODEL) { args += ["-F", "vad=true"] }
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    // Drain the pipe BEFORE waiting — a large transcript can fill the 64KB
    // pipe buffer and deadlock a waitUntilExit-first ordering.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = obj["text"] as? String else { return nil }
    return text
}

// v8.17: the hosted NessoTalk engine. Same multipart contract as the resident
// server plus the license headers its gate requires; machine/platform ride
// along for seat binding, and the engine discards audio after decoding. Any
// failure returns nil and the local path takes over, so Brady (and every
// customer) keeps dictating through an engine outage.
func runWhisperViaCloud(wav: String, timeout: Double) -> String? {
    guard cfg.cloud, !cfg.licenseKey.isEmpty, licenseValid else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", String(Int(timeout)),
                   cfg.transcribeUrl,
                   "-H", "x-license-key: \(cfg.licenseKey)",
                   "-F", "machine=\(machineID())",
                   "-F", "platform=mac",
                   "-F", "file=@\(wav)",
                   "-F", "language=\(cfg.language)",
                   "-F", "prompt=\(effectivePrompt())"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    // Drain before waiting — same 64KB pipe-deadlock rule as the server path.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = obj["text"] as? String, !text.isEmpty else { return nil }
    return text
}

// ===================== AI prompt-polish =====================
// Expansion-first rewrite for AI-directed dictation: restructure the transcript
// into headers + lists while keeping EVERY detail and unpacking each spoken
// thought into its full meaning — output should be as long or longer than the
// transcript, never a compressed summary (Brady's 2026-07-30 requirement after
// polish kept dropping details). Self-corrections still resolve to the FINAL
// decision. Runs only when the paste target is an AI app; any failure pastes
// the raw text.
let POLISH_INSTRUCTION = """
Rewrite this dictated transcript into a clear, well-structured document for an AI assistant. Rules:
- Keep EVERY specific detail: names, numbers, prices, file paths, product names, constraints, sequences, conditions, and examples. Losing a detail is the worst possible failure.
- EXPAND, never compress: unpack each spoken thought into its complete meaning. Where the speaker implies something without spelling it out, state the full idea they clearly meant. The output should be AS LONG OR LONGER than the transcript — it is a restructuring, not a summary.
- Keep the speaker's full reasoning and the WHY behind each decision, not just the conclusions.
- Resolve self-corrections to the FINAL decision only (e.g. "Tuesday, no wait, Wednesday" -> Wednesday).
- Organize with headers and numbered or dashed lists that follow the speaker's own structure.
- Sharpen vague phrasing into direct imperatives; keep the speaker's intent and scope exactly.
- Do NOT invent requirements the speaker didn't state, do NOT answer or act on the content, do NOT drop or condense anything away.
Output ONLY the rewritten text, no preamble, no commentary.
"""

// "Professional" mode (v8.3, Brady's spec): the speaker's OWN words with the
// noise removed — a transcription cleanup, NOT a rewrite. Output length stays
// close to the input minus fillers, so the trust gate is 1/2 (see polishForText).
let POLISH_TEXT_INSTRUCTION = """
Clean up this dictated transcript. Output the speaker's own words with the speech noise removed. This is a cleanup, NOT a rewrite and NOT a summary. Rules:
- Keep the speaker's own words, phrasing, and sentence order. Do not rephrase, restructure, condense, or expand anything.
- Remove filler words and sounds: um, uh, er, "you know", "I mean", "sort of", "kind of", "basically", "like" ONLY where they carry no meaning. Also remove false starts, stutters, and accidentally repeated words.
- Resolve self-corrections to the FINAL version only (e.g. "Tuesday, no wait, Wednesday" becomes Wednesday).
- Fix punctuation, capitalization, and obvious grammar slips so it reads as clean written text.
- Keep every fact, name, number, date, amount, and commitment exactly as spoken. Never add content. Never drop a point.
- Never use em dashes or en dashes anywhere. Use a period, comma, or colon instead.
- No greeting, sign-off, subject line, or commentary the speaker didn't say.
Output ONLY the cleaned text.
"""

func polishViaAPI(_ text: String, timeout: Double, instruction: String = POLISH_INSTRUCTION) -> String? {
    let body: [String: Any] = [
        "model": cfg.polishModel,
        "max_tokens": 16000,
        "messages": [["role": "user", "content": instruction + "\n\nTranscript:\n" + text]]
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    let reqFile = "/tmp/ptt_polish_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: reqFile) }
    guard (try? json.write(to: URL(fileURLWithPath: reqFile))) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", String(Int(timeout)),
                   "https://api.anthropic.com/v1/messages",
                   "-H", "x-api-key: \(cfg.polishKey)",
                   "-H", "anthropic-version: 2023-06-01",
                   "-H", "content-type: application/json",
                   "-d", "@\(reqFile)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let content = obj["content"] as? [[String: Any]],
          let t = content.first?["text"] as? String else { return nil }
    return t
}

// Groq-hosted Llama-3.3-70B: ~1000 tok/s — a full rewrite lands in ~1-2s,
// ~10× faster than the claude-CLI path. Used when POLISH_KEY starts with gsk_.
func polishViaGroq(_ text: String, timeout: Double, instruction: String = POLISH_INSTRUCTION) -> String? {
    let body: [String: Any] = [
        "model": "llama-3.3-70b-versatile",
        "max_tokens": 8192,
        "temperature": 0.2,
        "messages": [["role": "system", "content": instruction],
                     ["role": "user", "content": text]]
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    let reqFile = "/tmp/ptt_polish_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: reqFile) }
    guard (try? json.write(to: URL(fileURLWithPath: reqFile))) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", String(Int(timeout)),
                   "https://api.groq.com/openai/v1/chat/completions",
                   "-H", "Authorization: Bearer \(cfg.polishKey)",
                   "-H", "content-type: application/json",
                   "-d", "@\(reqFile)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = obj["choices"] as? [[String: Any]],
          let msg = choices.first?["message"] as? [String: Any],
          let t = msg["content"] as? String else { return nil }
    return t
}

func polishViaClaudeCLI(_ text: String, timeout: Double, instruction: String = POLISH_INSTRUCTION) -> String? {
    let cli = "\(HOME)/.local/bin/claude"
    guard FileManager.default.fileExists(atPath: cli) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cli)
    p.arguments = ["--model", cfg.polishModel, "-p", instruction]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    inPipe.fileHandleForWriting.write(text.data(using: .utf8)!)
    inPipe.fileHandleForWriting.closeFile()
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
        if let p = p, p.isRunning { p.terminate() }
    }
    // Drain before waiting — a long rewrite can fill the 64KB pipe buffer.
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, let t = String(data: data, encoding: .utf8) else { return nil }
    return t
}

// Screen context, Wispr-style: frontmost app name + focused window title (via
// the Accessibility grant the daemon already holds). Feeds the polish rewrites
// so tone/references fit the destination — NEVER the decode (prompt ceiling).
func frontContext() -> String {
    guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
    var out = app.localizedName ?? ""
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    var win: CFTypeRef?
    if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &win) == .success,
       let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() {
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
           let t = title as? String, !t.isEmpty {
            out += ", window \"\(String(t.prefix(120)))\""
        }
    }
    return out
}

// One context line appended to a polish instruction (empty context = no-op).
func contextSuffix(_ c: String) -> String {
    var s = ""
    if !c.isEmpty {
        s += "\nContext: the user is dictating into \(c). Write what fits that destination; never mention this context."
    }
    if !cfg.style.isEmpty {
        s += "\nHouse style, always apply: \(cfg.style). Keep this voice in every sentence without mentioning it."
    }
    return s
}

// Speculative rewrite cache (v8.8, YouTube-style preload): rewrites start
// BEFORE they're needed — during the pre-stop pause (the spec pass just
// decoded the tail, so the full transcript already exists) or at stop time —
// so delivery finds the work finished instead of starting it. The race is
// keyed on the exact transcript+context: resuming speech changes the text,
// which safely invalidates the guess (a stale worker's result is discarded).
final class PolishRace {
    private let lock = DispatchQueue(label: "ptt.race.lock")
    private var key = ""                          // transcript+context identity
    private var groups: [String: DispatchGroup] = [:]
    private var results: [String: String?] = [:]

    // Start every missing mode for this transcript. A no-op for modes already
    // in flight for the SAME text — that is what lets the spec pass, a second
    // spec pass, and the stop tap all call this without duplicate API calls.
    // A different text wipes the race and starts fresh; superseded workers
    // still leave their (now orphaned) groups, but their results are dropped.
    func ensure(_ text: String, context: String, modes: [String]) {
        let k = text + "\u{1}" + context
        var started: [(String, DispatchGroup)] = []
        lock.sync {
            if key != k { key = k; groups.removeAll(); results.removeAll() }
            for m in modes where groups[m] == nil {
                let g = DispatchGroup()
                g.enter()
                groups[m] = g
                started.append((m, g))
            }
        }
        guard !started.isEmpty else { return }
        for (mode, g) in started {
            DispatchQueue.global(qos: .userInitiated).async {
                let words = Double(text.split(separator: " ").count)
                let r: String?
                switch mode {
                case "summarize":    r = polishForAI(text, context: context)
                case "professional": r = polishForText(text, context: context)
                default:             r = polishViaProxy(text, timeout: max(45.0, words / 4.0), mode: mode)?
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.lock.sync {
                    if self.key == k { self.results[mode] = (r?.isEmpty == false) ? r : nil }
                }
                g.leave()   // ALWAYS leave: releasing an entered group crashes libdispatch
            }
        }
        log("⚡ pre-running \(started.map { $0.0 }.joined(separator: "+")) in the background")
    }

    // Outer nil means no race exists for this exact transcript (the caller
    // runs the rewrite inline). Inner nil means it ran and failed (the caller
    // pastes the raw transcript).
    func take(_ mode: String, text: String, context: String, timeout: Double) -> String?? {
        let k = text + "\u{1}" + context
        var g: DispatchGroup?
        lock.sync { if key == k { g = groups[mode] } }
        guard let g = g, g.wait(timeout: .now() + timeout) == .success else { return nil }
        var r: String?? = nil
        lock.sync { if key == k { r = results[mode] } }
        return r
    }
}
let polishRace = PolishRace()

// Which rewrites a stop could need: the picked mode's, or — when nothing is
// picked — whatever the no-click flow might route to (the default mode, plus
// Professional because the auto-Professional apps can still claim the paste).
func raceModes(for picked: DeliverMode, defaultMode: String) -> [String] {
    if let m = picked.proxyMode { return [m] }
    if picked == .raw { return [] }
    switch defaultMode {
    case "agent":        return ["agent", "professional"]
    case "expand":       return ["expand", "professional"]
    case "normal":       return ["professional"]
    case "professional": return ["professional"]
    default:             return ["summarize", "professional"]
    }
}

// Returns the polished text, or nil when the caller should paste the raw
// transcript instead (no backend, timeout, or an untrustworthy rewrite).
// Licensed transport: the rewrite runs on nesso.tech under OUR API key, gated
// on a live license. Customers never need their own key, and a cracked copy
// gets nothing here (402) — the capability was never on their machine.
// mode: "summarize" | "professional" | "command".
func polishViaProxy(_ text: String, timeout: Double, mode: String) -> String? {
    guard !cfg.licenseKey.isEmpty else { return nil }
    let body: [String: Any] = ["key": cfg.licenseKey, "mode": mode, "text": text]
    guard let json = try? JSONSerialization.data(withJSONObject: body) else { return nil }
    let reqFile = "/tmp/ptt_proxy_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: reqFile) }
    guard (try? json.write(to: URL(fileURLWithPath: reqFile))) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", String(Int(timeout)), cfg.polishProxyUrl,
                   "-H", "content-type: application/json", "-d", "@\(reqFile)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let err = obj["error"] as? String {
        log("· proxy rewrite unavailable (\(err))")
        return nil
    }
    return obj["text"] as? String
}

// ── Local mode transforms (no AI, no network, no key) ────────────────────────
// Deterministic code versions of the rewrite modes. They are the floor, not the
// ceiling: every AI transport is tried first, and only when none can answer
// (no key, no license, offline) does the picked mode fall back to these instead
// of silently pasting the raw transcript. Pure functions over the transcript
// text; they reference no file-scope globals (the Config.load ordering rule).

func splitIntoSentences(_ text: String) -> [String] {
    var out: [String] = []
    var cur = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        cur.append(chars[i])
        if chars[i] == "." || chars[i] == "?" || chars[i] == "!" {
            // Only a real sentence end when followed by whitespace and an
            // uppercase or digit start, or end of text: "theme.ts" and "3.5"
            // stay whole, and a lowercase continuation stays in the sentence.
            var j = i + 1
            while j < chars.count && chars[j] == " " { j += 1 }
            let atEnd = j >= chars.count
            if atEnd || (j > i + 1 && (chars[j].isUppercase || chars[j].isNumber)) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        i += 1
    }
    let t = cur.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { out.append(t) }
    return out
}

// "start tuesday no wait wednesday" -> "start wednesday". A short correction
// replaces the same number of trailing words; a long one replaces the clause
// back to the previous comma. Conservative marker list on purpose: a missed
// correction reads fine, a false positive eats real words.
func resolveSelfCorrections(_ sentence: String) -> String {
    let marker = "(?i)\\b(?:no,?\\s+wait|wait,?\\s+no|scratch that|actually,?\\s+no|no,?\\s+actually|i mean,)\\b[,.]?\\s*"
    var s = sentence
    while let m = s.range(of: marker, options: .regularExpression) {
        let before = String(s[..<m.lowerBound])
        let after = String(s[m.upperBound...])
        let afterWords = after.split(separator: " ")
        if !afterWords.isEmpty && afterWords.count <= 3 {
            var beforeWords = before.split(separator: " ").map(String.init)
            beforeWords.removeLast(min(afterWords.count, beforeWords.count))
            s = (beforeWords + [after]).joined(separator: " ")
        } else if let comma = before.range(of: ",", options: .backwards) {
            s = String(before[..<comma.lowerBound]) + ", " + after
        } else {
            s = after
        }
    }
    return s
}

func stripSpokenFiller(_ sentence: String) -> String {
    var s = sentence
    // Throat-clearing stacks ("okay so um…"), so the lead rule loops.
    let lead = "(?i)^(?:ok(?:ay)?|so|yeah|alright|well|anyway|um|uh)[,]?\\s+"
    while let r = s.range(of: lead, options: .regularExpression) { s.removeSubrange(r) }
    // v8.21, grounded in the disfluency literature: filled pauses and PURE
    // discourse markers strip safely, but hedges carry meaning ("kind of
    // broken" is a real report), so kind of / sort of / right? stay.
    let rules: [(String, String)] = [
        ("(?i),\\s*(?:like|you know|i mean|i guess)\\s*,", ","),
        ("(?i)\\b(?:you know|i guess|basically|literally)\\s*,\\s*", ""),
        // Trailing throwaways that close a clause without adding content.
        ("(?i),?\\s*(?:you know what i mean|if that makes sense|or whatever|and stuff(?: like that)?|and everything)\\s*([,.?!]|$)", "$1"),
        // Stutter doubles on function words ("the the", "to to") are never
        // deliberate, unlike "very very" or "no no", which stay.
        ("(?i)\\b(the|a|an|to|of|in|on|at|and|but|or|we|i|it|is|was|for|with)\\s+\\1\\b", "$1"),
        ("\\s{2,}", " "),
    ]
    for (p, r) in rules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
    return s.trimmingCharacters(in: .whitespaces)
}

// Whisper hears contractions without the apostrophe; put it back for the safe
// unambiguous set only ("ill", "id", "its" stay untouched, they have real
// non-contraction readings).
func fixContractions(_ s: String) -> String {
    let map: [(String, String)] = [
        ("(?i)\\bdont\\b", "don't"), ("(?i)\\bcant\\b", "can't"), ("(?i)\\bwont\\b", "won't"),
        ("(?i)\\bdidnt\\b", "didn't"), ("(?i)\\bdoesnt\\b", "doesn't"), ("(?i)\\bisnt\\b", "isn't"),
        ("(?i)\\bwasnt\\b", "wasn't"), ("(?i)\\bcouldnt\\b", "couldn't"), ("(?i)\\bshouldnt\\b", "shouldn't"),
        ("(?i)\\bwouldnt\\b", "wouldn't"), ("(?i)\\bhasnt\\b", "hasn't"), ("(?i)\\bhavent\\b", "haven't"),
        ("(?i)\\bthats\\b", "that's"), ("(?i)\\bwhats\\b", "what's"), ("(?i)\\bheres\\b", "here's"),
        ("(?i)\\btheres\\b", "there's"), ("(?i)\\byoure\\b", "you're"), ("(?i)\\btheyre\\b", "they're"),
        // v8.21: the rest of the unambiguous set. Every one of these is a
        // non-word without its apostrophe ("lets", "were", "its", "ill", "id"
        // all have real readings and stay out).
        ("(?i)\\barent\\b", "aren't"), ("(?i)\\bwerent\\b", "weren't"), ("(?i)\\bhadnt\\b", "hadn't"),
        ("(?i)\\byoull\\b", "you'll"), ("(?i)\\btheyll\\b", "they'll"), ("(?i)\\btheyve\\b", "they've"),
        ("(?i)\\bweve\\b", "we've"), ("(?i)\\byouve\\b", "you've"), ("(?i)\\btheyd\\b", "they'd"),
        ("(?i)\\bwhos\\b", "who's"), ("(?i)\\bhows\\b", "how's"), ("(?i)\\bwheres\\b", "where's"),
        ("(?i)\\bcouldve\\b", "could've"), ("(?i)\\bshouldve\\b", "should've"), ("(?i)\\bwouldve\\b", "would've"),
        ("(?i)\\bitll\\b", "it'll"), ("(?i)\\bthatll\\b", "that'll"), ("(?i)\\bmustve\\b", "must've"),
        ("\\bim\\b", "I'm"), ("\\bive\\b", "I've"), ("\\bi\\b", "I"),
    ]
    var t = s
    for (p, r) in map { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
    return t
}

func sentenceCased(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return t }
    t = t.prefix(1).uppercased() + String(t.dropFirst())
    if let last = t.last, !".?!:".contains(last) { t += "." }
    return t
}

// Spoken units read badly as words: "35 percent" -> "35%", "9 am" -> "9 AM".
// Digit-anchored so "I am" and prose uses of "percent of people" style phrases
// without a number are never touched.
func formatSpokenUnits(_ s: String) -> String {
    var t = formatSpokenMoney(s)
    t = t.replacingOccurrences(of: "\\b(\\d+(?:\\.\\d+)?) percent\\b",
                               with: "$1%", options: .regularExpression)
    if let rx = try? NSRegularExpression(pattern: "\\b(\\d{1,2}(?::\\d{2})?)\\s?(am|pm)\\b",
                                         options: .caseInsensitive) {
        let ns = t as NSString
        for m in rx.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
            let time = (t as NSString).substring(with: m.range(at: 1))
            let suffix = (t as NSString).substring(with: m.range(at: 2)).uppercased()
            t = (t as NSString).replacingCharacters(in: m.range, with: time + " " + suffix)
        }
    }
    return t
}

// v8.21 deep typography: curly apostrophes and a real ellipsis at paste time,
// but ONLY for prose targets. Code apps (the POLISH_APPS list: terminals and
// editors) get untouched ASCII, because a curly quote in a terminal is
// corruption, not typography, and "..." in Swift is a range operator. Text
// carrying backticks is left alone in every app.
func smartTypography(_ text: String, bundleId: String) -> String {
    let lower = bundleId.lowercased()
    for app in cfg.polishApps.split(separator: ",")
    where !app.isEmpty && lower.contains(String(app)) { return text }
    if text.contains("`") { return text }
    var t = text.replacingOccurrences(of: "(?<=[A-Za-z])'(?=[A-Za-z])",
                                      with: "\u{2019}", options: .regularExpression)
    t = t.replacingOccurrences(of: "...", with: "\u{2026}")
    return t
}

// Days and months are always capitalized in written English, and whisper
// writes them lowercase mid-sentence ("we ship tuesday"). This is orthography,
// not rewording, so it is safe in every mode including Professional, which is
// otherwise forbidden from changing the speaker's words.
// "May" and "March" are deliberately absent: they are ordinary words far more
// often than months in speech, and a wrong capital is worse than a missing one.
let CALENDAR_WORDS = ["monday", "tuesday", "wednesday", "thursday", "friday",
                      "saturday", "sunday", "january", "february", "april",
                      "june", "july", "august", "september", "october",
                      "november", "december"]

func capitalizeCalendar(_ s: String) -> String {
    var t = s
    for w in CALENDAR_WORDS {
        t = t.replacingOccurrences(of: "\\b\(w)\\b",
                                   with: w.prefix(1).uppercased() + w.dropFirst(),
                                   options: [.regularExpression, .caseInsensitive])
    }
    return t
}

func cleanedSentences(_ text: String) -> [String] {
    return splitIntoSentences(text)
        .map { capitalizeCalendar(formatSpokenUnits(fixContractions(stripSpokenFiller(resolveSelfCorrections($0))))) }
        .filter { !$0.isEmpty }
}

// Spoken task descriptions are comma-glued run-ons, so the agent brief sorts
// CLAUSES, not sentences. Tiny fragments merge back into their neighbor.
func taskClauses(_ text: String) -> [String] {
    var clauses: [String] = []
    for s in cleanedSentences(text) {
        for piece in s.components(separatedBy: ", ") {
            var c = piece.trimmingCharacters(in: .whitespaces)
            c = c.replacingOccurrences(of: "(?i)^(?:and|but|then|also)\\s+", with: "", options: .regularExpression)
            if c.isEmpty { continue }
            if c.split(separator: " ").count < 3, var last = clauses.popLast() {
                last += ", " + c
                clauses.append(last)
            } else {
                clauses.append(c)
            }
        }
    }
    return clauses
}

// Whisper glues spoken clauses into comma run-ons. For prose output, split at
// ", and / , but / , so " when BOTH sides are substantial (4+ words) — short
// tails stay attached so lists and asides don't shatter.
func splitRunOns(_ sentence: String) -> [String] {
    var parts = [sentence]
    for joiner in [", and ", ", but ", ", so "] {
        parts = parts.flatMap { part -> [String] in
            var out: [String] = []
            var rest = part
            while let r = rest.range(of: joiner) {
                let head = String(rest[..<r.lowerBound])
                let tail = String(rest[r.upperBound...])
                guard head.split(separator: " ").count >= 4,
                      tail.split(separator: " ").count >= 4 else { break }
                out.append(head)
                rest = tail
            }
            out.append(rest)
            return out
        }
    }
    return parts
}

// Spoken money reads badly as digits-plus-words. "4500 dollars" becomes
// "$4,500" — ONLY when the word "dollars" anchors it, so invoice numbers,
// years, and IDs are never touched.
func formatSpokenMoney(_ s: String) -> String {
    guard let rx = try? NSRegularExpression(pattern: "\\b(\\d{1,9}) dollars\\b",
                                            options: .caseInsensitive) else { return s }
    var t = s
    let ns = t as NSString
    for m in rx.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
        let numStr = (t as NSString).substring(with: m.range(at: 1))
        guard let n = Int(numStr) else { continue }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let pretty = fmt.string(from: NSNumber(value: n)) ?? numStr
        t = (t as NSString).replacingCharacters(in: m.range, with: "$" + pretty)
    }
    return t
}

// Dictated questions arrive with a period. Fix the unambiguous shapes only:
// an auxiliary followed by a subject ("can you", "is it"), or a wh-word
// followed by an auxiliary ("what is", "how do"). "What I want is X" keeps
// its period because a pronoun follows the wh-word, not an auxiliary.
func inferQuestion(_ s: String) -> String {
    guard s.hasSuffix(".") else { return s }
    let aux = "(?:can|could|would|will|should|shall|do|does|did|is|are|was|were|am|have|has|won'?t|don'?t|didn'?t|isn'?t|aren'?t|shouldn'?t|couldn'?t|wouldn'?t)"
    let subject = "(?:you|we|i|it|they|he|she|that|this|there|anyone|the)"
    let wh = "(?:what|when|where|why|how|who|which)"
    let starts = "(?i)^(?:\(aux) \(subject)\\b|\(wh) \(aux)\\b|\(wh) (?:about|much|many|long|often|soon)\\b)"
    guard s.range(of: starts, options: .regularExpression) != nil else { return s }
    return String(s.dropLast()) + "?"
}

// Greeting on its own line when the dictation opens with one ("hey john" ->
// "Hey John," + line break). Anchored to a tiny opener list and <=4 words, so
// "hey can you check the deploy" is never split.
func splitGreeting(_ sentences: [String]) -> (greeting: String?, rest: [String]) {
    guard let first = sentences.first else { return (nil, sentences) }
    let bare = first.hasSuffix(".") ? String(first.dropLast()) : first
    let pat = "(?i)^(?:hey|hi|hello|good morning|good afternoon|good evening|dear) [a-z]+(?: [a-z]+)?$"
    guard bare.split(separator: " ").count <= 4,
          bare.range(of: pat, options: .regularExpression) != nil else { return (nil, sentences) }
    var g = bare.prefix(1).uppercased() + bare.dropFirst()
    // Cap the name too: "hey john" -> "Hey John,"
    var words = g.split(separator: " ").map(String.init)
    if let last = words.last { words[words.count - 1] = last.prefix(1).uppercased() + last.dropFirst() }
    g = words.joined(separator: " ")
    return (g + ",", Array(sentences.dropFirst()))
}

// Sign-off gets its own line when the dictation closes with one. Short and
// anchored: "thanks", "thanks so much", "talk soon", "cheers", "best".
func splitSignoff(_ sentences: [String]) -> (rest: [String], signoff: String?) {
    guard let last = sentences.last else { return (sentences, nil) }
    let pat = "(?i)^(?:thanks|thank you|thanks so much|thanks a lot|cheers|best|talk soon|see you (?:then|soon|tomorrow)|appreciate it)[.,!]?$"
    guard last.split(separator: " ").count <= 4,
          last.range(of: pat, options: .regularExpression) != nil else { return (sentences, nil) }
    return (Array(sentences.dropLast()), sentenceCased(last))
}

// Professional: the speaker's own words, minus the junk, cased and punctuated.
// Unit formatting already happened in cleanedSentences, shared by every mode.
// v8.21 (email-convention research): greeting and sign-off get their own
// lines, questions get their question marks back, and long dictations break
// into 2-3 sentence paragraphs instead of one wall, because that is how
// people actually want a sent message to read.
func localProfessional(_ text: String) -> String {
    let sentences = cleanedSentences(text)
        .flatMap(splitRunOns)
        .map(sentenceCased)
        .map(inferQuestion)
    let (greeting, afterGreeting) = splitGreeting(sentences)
    let (body, signoff) = splitSignoff(afterGreeting)

    // 2-3 sentence paragraphs, but only once the message is long enough for
    // paragraphs to help; short messages stay one block.
    var paras: [String] = []
    if body.count <= 3 {
        if !body.isEmpty { paras.append(body.joined(separator: " ")) }
    } else {
        var cur: [String] = []
        for s in body {
            cur.append(s)
            if cur.count == 3 { paras.append(cur.joined(separator: " ")); cur = [] }
        }
        if !cur.isEmpty { paras.append(cur.joined(separator: " ")) }
    }

    var out: [String] = []
    if let g = greeting { out.append(g) }
    out.append(contentsOf: paras)
    if let s = signoff { out.append(s) }
    return out.joined(separator: "\n\n")
}

// Summarize: structure without condensing. Enumeration leads become a dashed
// list, topic shifts start a new paragraph, everything else groups into short
// paragraphs. Nothing is dropped.
func localSummarize(_ text: String) -> String {
    let listLead = "(?i)^(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|then|next|also|finally|lastly|on top of that|(?:number|point|step) \\w+)[,]?\\s+"
    let topicShift = "(?i)^(?:anyway|separately|one more thing|oh and|on another note|switching gears|next thing|the other thing|last thing|by the way|real quick|also wanted to)[,]?\\s+"
    // Short, self-contained commitments collect into an Action items block at
    // the end (v8.16). Long sentences with an action cue stay in place, since
    // pulling them out of their surrounding context would orphan them.
    let actionCue = "(?i)\\b(?:need(?:s)? to|have to|remember to|don'?t forget|make sure to|todo|to-do)\\b"
    // v8.21: decisions get the same treatment as actions. A skimmer wants
    // what was DECIDED and what to DO before anything else.
    let decisionCue = "(?i)\\b(?:we decided|i decided|we agreed|let'?s go with|the plan is|we'?re going with|the decision is|going to go with)\\b"
    var blocks: [String] = []
    var para: [String] = []
    var list: [String] = []
    var actions: [String] = []
    var decisions: [String] = []
    func flushPara() { if !para.isEmpty { blocks.append(para.joined(separator: " ")); para = [] } }
    func flushList() { if !list.isEmpty { blocks.append(list.map { "- " + $0 }.joined(separator: "\n")); list = [] } }
    let sentences = cleanedSentences(text).flatMap(splitRunOns)
    for s in sentences {
        if sentences.count > 2,
           s.split(separator: " ").count <= 20,
           s.range(of: decisionCue, options: .regularExpression) != nil {
            decisions.append(sentenceCased(s))
            continue
        }
        if sentences.count > 2,
           s.split(separator: " ").count <= 20,
           s.range(of: actionCue, options: .regularExpression) != nil {
            actions.append(sentenceCased(s))
            continue
        }
        if let r = s.range(of: listLead, options: .regularExpression), !s.isEmpty {
            flushPara()
            list.append(sentenceCased(String(s[r.upperBound...])))
        } else if let r = s.range(of: topicShift, options: .regularExpression) {
            flushList(); flushPara()
            para.append(sentenceCased(String(s[r.upperBound...])))
        } else {
            flushList()
            para.append(sentenceCased(s))
            if para.count >= 3 { flushPara() }
        }
    }
    flushList(); flushPara()
    if !decisions.isEmpty {
        blocks.append("Decisions\n" + decisions.map { "- " + $0 }.joined(separator: "\n"))
    }
    if !actions.isEmpty {
        blocks.append("Action items\n" + actions.map { "- " + $0 }.joined(separator: "\n"))
    }
    return blocks.joined(separator: "\n\n")
}

// Agent v2: weighted cue scoring per CLAUSE, tried at two strictness levels,
// and the better-shaped brief wins. Precision beats recall on purpose: an
// ambiguous clause stays in Goal, because a requirement filed under Goal still
// reads fine while a Goal clause filed under Constraints derails the agent.
// Every clause lands in exactly one section, so nothing is ever dropped.

// (section, pattern, weight). Built-ins first, then ~/.dictation/mode-rules
// ("constraint: hands off = 3"), hot-loaded on every use like learned-words,
// so the sorter improves without a rebuild.
func agentCueTable() -> [(String, String, Double)] {
    var cues: [(String, String, Double)] = [
        ("constraint", "\\b(?:don'?t|do not|shouldn'?t|should not|must not|never|avoid|without (?:breaking|touching)|only touch|hands off)\\b", 3),
        ("constraint", "\\b(?:make sure|keep (?:the|it|everything)|leave (?:the|it)|stay (?:away from|out of)|be careful)\\b", 2),
        ("done", "\\b(?:done when|it works when|tests? (?:pass|passing)|verify that|acceptance criteria)\\b", 3),
        ("done", "\\b(?:should (?:return|show|display|pass|see|survive)|expect(?:ed)? to|so that|when (?:i|you|it)'?m?s? (?:done|finished))\\b", 2),
        ("context", "\\b(?:error|stack trace|crash(?:es|ing)?|the bug|fails?|failing|broken)\\b", 3),
        ("context", "(?:\\b(?:currently|right now|at the moment|today it)\\b|[\\w-]+\\.(?:swift|ts|tsx|js|jsx|py|go|cs|rb|css|html|json|md)\\b|/[\\w./-]{3,})", 2),
        ("goal", "^(?:please\\s+)?(?:add|fix|build|make|create|update|change|remove|delete|implement|wire|write|move|rename|refactor|redesign|set up|hook up|clean up|deploy|ship|migrate|port|convert|integrate|optimize|speed up|install|configure|test|style|animate|publish|upgrade|swap|replace|extract|split|merge|connect|automate)\\b", 3),
        ("goal", "\\b(?:i (?:want|need) (?:you )?to|can you|we need to|the goal is|i'?m trying to)\\b", 3),
        ("goal", "\\b(?:it should|it needs to|there should be)\\b", 1.5),
        // v8.21 additions: deadlines and budgets are constraints, attempts
        // and current-state reports are context, outcome shapes are done.
        ("constraint", "\\b(?:has to stay|keep it under|no more than|at most|can'?t|cannot|instead of|rather than|without asking|asap|by (?:tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|the demo|end of (?:day|week))|deadline)\\b", 2),
        ("done", "\\b(?:end result|final result|should end up|once it'?s|success (?:is|means)|i can tell it worked|at the end|the output should)\\b", 2),
        ("context", "\\b(?:i tried|we tried|last time|yesterday|the problem is|what'?s happening is|the repo|the branch|the pr|right now it)\\b", 2),
    ]
    let path = NSHomeDirectory() + "/.dictation/mode-rules"
    if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
        for line in raw.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#"), let colon = l.firstIndex(of: ":") else { continue }
            let section = String(l[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard ["goal", "constraint", "done", "context"].contains(section) else { continue }
            var phrase = String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var weight = 2.0
            if let eq = phrase.range(of: "=", options: .backwards) {
                let w = String(phrase[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let d = Double(w) {
                    weight = d
                    phrase = String(phrase[..<eq.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !phrase.isEmpty else { continue }
            cues.append((section, "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b", weight))
        }
    }
    return cues
}

func buildAgentBrief(_ clauses: [String], cues: [(String, String, Double)],
                     threshold: Double) -> (brief: String, quality: Double) {
    var goal: [String] = [], constraints: [String] = [], done: [String] = [], context: [String] = []
    for (i, c) in clauses.enumerated() {
        // The opening clause is the goal until strong evidence says otherwise.
        var score: [String: Double] = ["goal": i == 0 ? 2 : 0, "constraint": 0, "done": 0, "context": 0]
        for (section, pattern, weight) in cues
        where c.range(of: "(?i)" + pattern, options: .regularExpression) != nil {
            score[section, default: 0] += weight
        }
        let g = score["goal"] ?? 0
        let best = ["constraint", "done", "context"].max { (score[$0] ?? 0) < (score[$1] ?? 0) }!
        // A clause only leaves Goal when its cue evidence clears the bar AND
        // beats its goal evidence — the never-misort policy in one line.
        if let s = score[best], s >= threshold, s > g {
            switch best {
            case "constraint": constraints.append(c)
            case "done":       done.append(c)
            default:           context.append(c)
            }
        } else {
            goal.append(c)
        }
    }
    // Shape score: a brief with a goal and balanced sections beats one that
    // dumped everything into a single bucket.
    var quality = 0.0
    quality += goal.isEmpty ? -4 : 3
    quality += Double([constraints, done, context].filter { !$0.isEmpty }.count)
    let total = Double(clauses.count)
    for bucket in [constraints, done, context] where Double(bucket.count) > total * 0.5 { quality -= 2 }
    var out: [String] = []
    if !goal.isEmpty { out.append("Goal\n" + goal.map(sentenceCased).joined(separator: " ")) }
    if !constraints.isEmpty { out.append("Constraints\n" + constraints.map { "- " + sentenceCased($0) }.joined(separator: "\n")) }
    if !done.isEmpty { out.append("Done when\n" + done.map { "- " + sentenceCased($0) }.joined(separator: "\n")) }
    if !context.isEmpty { out.append("Context\n" + context.map { "- " + sentenceCased($0) }.joined(separator: "\n")) }
    return (out.joined(separator: "\n\n"), quality)
}

func localAgentBrief(_ text: String) -> String {
    let clauses = taskClauses(text)
    guard !clauses.isEmpty else { return localProfessional(text) }
    let cues = agentCueTable()
    // Deliberation: the engine builds the brief more than one way and keeps the
    // better-shaped result. Ties go to strict — fewer moves, fewer misfiles.
    var best = buildAgentBrief(clauses, cues: cues, threshold: 3.0)
    let lenient = buildAgentBrief(clauses, cues: cues, threshold: 2.0)
    if lenient.quality > best.quality { best = lenient }
    return best.brief.isEmpty ? localProfessional(text) : best.brief
}

// Expand: code cannot invent detail, so instead of padding it asks. The
// cleaned request plus the unstated dimensions as open questions. v8.12: the
// questions are domain-aware — a UI request, an API request, and a bug report
// each get asked what actually goes unstated in that kind of request.
func localExpand(_ text: String) -> String {
    let doneCues = "(?i)\\b(?:done when|should (?:return|show|display|work|pass|see)|expect(?:ed)? to|so that|it works when|tests? pass|verify that)\\b"
    let constraintCues = "(?i)\\b(?:don'?t|do not|shouldn'?t|should not|must not|never|avoid|without (?:breaking|touching)|keep (?:the|it|everything)|leave (?:the|it)|make sure|only touch)\\b"
    let edgeCues = "(?i)\\b(?:empty|missing|invalid|malformed|edge case|error|fail)\\b"
    let cleaned = localProfessional(text)
    var qs: [String] = []
    // Domain questions first — they are the sharpest ones.
    let domains: [(String, String)] = [
        ("(?i)\\b(?:page|button|screen|form|modal|toggle|menu|dropdown|the ui)\\b",
         "- What should the loading, empty, and error states look like?"),
        ("(?i)\\b(?:api|endpoint|route|webhook|request|server)\\b",
         "- What are the auth, rate limit, and error response expectations?"),
        ("(?i)\\b(?:bug|broken|crash|doesn'?t work|not working)\\b",
         "- What are the exact steps that reproduce it, and what should happen instead?"),
        ("(?i)\\b(?:database|table|migration|schema|column)\\b",
         "- Does anything need migrating, and what happens to existing rows?"),
        ("(?i)\\b(?:payment|checkout|billing|stripe|subscription|invoice)\\b",
         "- What should happen on a failed, disputed, or refunded payment?"),
        ("(?i)\\b(?:login|log in|signup|sign up|auth|password|session)\\b",
         "- Which users does this apply to, and what happens to existing sessions?"),
        ("(?i)\\b(?:slow|laggy|lag|latency|speed up|performance|faster|quicker)\\b",
         "- What is the acceptable number, concretely: how fast is fast enough?"),
        ("(?i)\\b(?:deploy|release|ship it|rollout|roll out)\\b",
         "- Is there a rollout order or migration involved, and is rollback required?"),
        ("(?i)\\b(?:email|outreach|message to|reach out|follow up with)\\b",
         "- Who exactly is the recipient, what tone, and what is the one thing they should do after reading?"),
        ("(?i)\\b(?:post|video|caption|tweet|blog|content)\\b",
         "- Which platform and audience is this for, and how long should it be?"),
        ("(?i)\\b(?:report|export|csv|spreadsheet|analytics|dashboard)\\b",
         "- Which columns or metrics, over what time period, in what format?"),
        ("(?i)\\b(?:test|tests|coverage)\\b",
         "- Which behaviors must be covered, and what counts as passing?"),
    ]
    for (cue, q) in domains where text.range(of: cue, options: .regularExpression) != nil {
        qs.append(q)
        if qs.count >= 2 { break }
    }
    let domainMatched = !qs.isEmpty
    if text.range(of: doneCues, options: .regularExpression) == nil { qs.append("- What does done look like, concretely?") }
    // The generic input-shape question only earns its place when no sharper
    // domain question fired.
    if !domainMatched, text.range(of: edgeCues, options: .regularExpression) == nil {
        qs.append("- What should happen when the input is empty, missing, or malformed?")
    }
    if qs.count < 4, text.range(of: constraintCues, options: .regularExpression) == nil {
        qs.append("- Is there anything that must not change?")
    }
    return qs.isEmpty ? cleaned : cleaned + "\n\nOpen questions:\n" + qs.joined(separator: "\n")
}

// Fact guardrail: a transform may reorganize, never lose. Every number that
// survives cleanup must appear in the output, or the safer cleaned text ships
// instead. This is a guarantee code can make that a model cannot.
func numberTokens(_ s: String) -> [String] {
    guard let rx = try? NSRegularExpression(pattern: "\\d[\\d,.]*\\d|\\d") else { return [] }
    let ns = s as NSString
    return rx.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}

func factGuardrail(cleaned: String, candidate: String) -> String {
    var pool = numberTokens(candidate)
    for n in numberTokens(cleaned) {
        if let i = pool.firstIndex(of: n) { pool.remove(at: i) }
        else { return cleaned }
    }
    return candidate
}

func localModeTransform(_ text: String, mode: String) -> String {
    let cleaned = localProfessional(text)
    let candidate: String
    switch mode {
    case "summarize":    candidate = localSummarize(text)
    case "professional": return cleaned
    case "agent":        candidate = localAgentBrief(text)
    case "expand":       candidate = localExpand(text)
    default:             return text
    }
    return factGuardrail(cleaned: cleaned, candidate: candidate)
}

// ── Self-tuning layer ────────────────────────────────────────────────────────
// Two plain files under ~/.dictation let the engine change with use, no model:
//  - mode-rules: extra cue phrases for the agent sorter, yours or future
//    machine-suggested ones, hot-loaded on every dictation (agentCueTable).
//  - mode-usage: every explicit HUD mode pick, per app. Three-plus picks with
//    a 60% majority make that mode the app's default until the habit changes.

func recordModePick(app: String, mode: String) {
    guard !app.isEmpty else { return }
    let path = NSHomeDirectory() + "/.dictation/mode-usage"
    let line = app + "\t" + mode + "\n"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(Data(line.utf8))
        fh.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    // Keep the habit file small and recent so old habits can fade.
    if let all = try? String(contentsOfFile: path, encoding: .utf8) {
        let lines = all.split(separator: "\n")
        if lines.count > 1000 {
            try? (lines.suffix(500).joined(separator: "\n") + "\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}

func learnedModeFor(app: String) -> String? {
    guard !app.isEmpty,
          let all = try? String(contentsOfFile: NSHomeDirectory() + "/.dictation/mode-usage",
                                encoding: .utf8) else { return nil }
    var counts: [String: Int] = [:]
    var total = 0
    for line in all.split(separator: "\n").suffix(200) {
        let parts = line.split(separator: "\t")
        guard parts.count == 2, String(parts[0]) == app else { continue }
        counts[String(parts[1]), default: 0] += 1
        total += 1
    }
    guard total >= 3, let top = counts.max(by: { $0.value < $1.value }),
          Double(top.value) >= Double(total) * 0.6 else { return nil }
    return top.key
}

func polishForAI(_ text: String, context: String = "") -> String? {
    let words = text.split(separator: " ").count
    let timeout = max(30.0, Double(words) / 4.0)     // expansion writes MORE than the transcript
    let inst = POLISH_INSTRUCTION + contextSuffix(context)
    var out: String?
    out = polishViaProxy(text, timeout: timeout, mode: "summarize")
    if out == nil, cfg.polishKey.hasPrefix("gsk_") { out = polishViaGroq(text, timeout: timeout, instruction: inst) }
    else if out == nil, !cfg.polishKey.isEmpty { out = polishViaAPI(text, timeout: timeout, instruction: inst) }
    if out == nil { out = polishViaClaudeCLI(text, timeout: timeout, instruction: inst) }
    guard let t = out?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    // Trust gates: a refusal / meta answer / heavy content loss means we paste
    // Brady's words, not the model's commentary.
    let lower = t.lowercased()
    if lower.hasPrefix("i can't") || lower.hasPrefix("i cannot") || lower.hasPrefix("i'm sorry")
        || lower.hasPrefix("here is the rewritten") || lower.hasPrefix("here's the rewritten") {
        return nil
    }
    // Expansion contract: output should be >= transcript length. Under 60% of
    // the input means the model summarized details away — paste Brady's words.
    if t.count < text.count * 3 / 5 { return nil }
    return t
}

// "Professional" rewrite for texting/email. Same transport chain and refusal
// gates as polishForAI, but with the text/email instruction and a LOOSER length
// gate: cleaning a rambling gist legitimately condenses, so only a collapse
// below 30% of the input (message summarized away) rejects to raw.
func polishForText(_ text: String, context: String = "") -> String? {
    let words = text.split(separator: " ").count
    let timeout = max(25.0, Double(words) / 5.0)
    let inst = POLISH_TEXT_INSTRUCTION + contextSuffix(context)
    var out: String?
    out = polishViaProxy(text, timeout: timeout, mode: "professional")
    if out == nil, cfg.polishKey.hasPrefix("gsk_") { out = polishViaGroq(text, timeout: timeout, instruction: inst) }
    else if out == nil, !cfg.polishKey.isEmpty { out = polishViaAPI(text, timeout: timeout, instruction: inst) }
    if out == nil { out = polishViaClaudeCLI(text, timeout: timeout, instruction: inst) }
    guard let t = out?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    let lower = t.lowercased()
    if lower.hasPrefix("i can't") || lower.hasPrefix("i cannot") || lower.hasPrefix("i'm sorry")
        || lower.hasPrefix("here is the rewritten") || lower.hasPrefix("here's the rewritten") {
        return nil
    }
    // Cleanup only strips fillers — output under half the input means the model
    // summarized instead; paste raw. (Gate and instruction must stay paired:
    // a condensing prompt with this gate would reject nearly every polish.)
    if t.count < text.count / 2 { return nil }
    return t
}

// ===================== lease check-in (customer builds) =====================
// With a LICENSE_KEY set, the daemon phones nesso.tech on launch and every 12h,
// sending this machine's id (seat binding). The reply is SIGNED (Ed25519) with
// a private key that only the server holds, and verified here against the
// public key below — so redirecting nesso.tech to a fake local server that
// answers {"valid":true} does NOT work: the attacker cannot forge a signature.
// The last valid token is cached and honors its own expiry offline. The server
// issues 24 hours: this product is "we grant it and we take it away", so a long
// offline window would make revocation meaningless on a machine kept offline.
// Invalid/revoked/expired/seat-capped -> recording disarms (an in-flight
// session still finishes; we never eat words mid-recording). Empty key = dev.
let LICENSE_PUBKEY_B64 = "DgOqB8kIOGQDePmlGSFcbZVVbujNZ9CVM+XkPFSJZjw="
let APP_VERSION = "8.24"
var updateAvailable = ""   // newest version the server reports, empty when current
var licenseValid = true
let LICENSE_TOKEN_PATH = "\(HOME)/.dictation/.license_token"

// Stable per-machine id (IOPlatformUUID): the seat this install occupies.
func machineID() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "unknown" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    if let r = text.range(of: "\"IOPlatformUUID\" = \"([0-9A-Fa-f-]+)\"", options: .regularExpression),
       let q = text[r].range(of: "[0-9A-Fa-f-]{36}", options: .regularExpression) {
        return String(text[r][q])
    }
    return "unknown"
}

// True only if the signature is genuine AND the payload names this key+machine,
// says valid, and has not expired.
func tokenAccepted(token: String, sig: String) -> Bool {
    guard let pubData = Data(base64Encoded: LICENSE_PUBKEY_B64),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData),
          let body = Data(base64Encoded: token),
          let sigData = Data(base64Encoded: sig),
          key.isValidSignature(sigData, for: body),
          let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          (obj["valid"] as? Bool) == true,
          (obj["key"] as? String) == cfg.licenseKey,
          let exp = obj["exp"] as? Double, exp > Date().timeIntervalSince1970 * 1000
    else { return false }
    let m = obj["machine"] as? String ?? ""
    return m.isEmpty || m == machineID()
}

// No answer from the server: fall back to the last SIGNED token we stored.
func applyCachedToken() {
    guard let raw = try? String(contentsOfFile: LICENSE_TOKEN_PATH, encoding: .utf8) else {
        licenseValid = false
        log("✕ no cached license and the server is unreachable — dictation disarmed")
        return
    }
    let parts = raw.split(separator: "\n", maxSplits: 1).map(String.init)
    if parts.count == 2, tokenAccepted(token: parts[0], sig: parts[1]) {
        licenseValid = true
    } else {
        licenseValid = false
        log("✕ cached license expired and the server is unreachable — dictation disarmed")
    }
}

func checkLicense() {
    // No key = not licensed. (A ~/.dictation/.dev marker, which ships in no
    // build, keeps development machines running without one.)
    if cfg.licenseKey.isEmpty {
        if FileManager.default.fileExists(atPath: "\(HOME)/.dictation/.dev") {
            licenseValid = true
            return
        }
        licenseValid = false
        log("✕ no license key — sign in at nesso.tech and download your copy to activate")
        return
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "--max-time", "15", cfg.licenseUrl,
                   "-H", "Content-Type: application/json",
                   "-d", "{\"key\":\"\(cfg.licenseKey)\",\"machine\":\"\(machineID())\",\"platform\":\"mac\"}"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { applyCachedToken(); return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = obj["token"] as? String, let sig = obj["sig"] as? String
    else { applyCachedToken(); return }

    if let latest = obj["latest_version"] as? String, latest != APP_VERSION {
        updateAvailable = latest
        log("↑ NessoTalk \(latest) is available. Run: ptt update")
    } else {
        updateAvailable = ""
    }
    if tokenAccepted(token: token, sig: sig) {
        licenseValid = true
        try? "\(token)\n\(sig)".write(toFile: LICENSE_TOKEN_PATH, atomically: true, encoding: .utf8)
    } else {
        licenseValid = false
        let why = (obj["reason"] as? String) ?? "signature rejected"
        log("✕ license inactive (\(why)) — dictation disarmed, manage it at nesso.tech")
    }
}

// ===================== command mode (edit selection by voice) =====================
// Option + Right-⌘ tap: the current selection is captured (synthesized Cmd-C),
// a recording starts, and the spoken words become an EDIT INSTRUCTION for the
// selection. On stop, the rewritten text pastes back over the still-highlighted
// selection. Any failure pastes NOTHING (the selection is left untouched).
let COMMAND_INSTRUCTION = """
You are a text editor. You will receive SELECTED TEXT and a spoken INSTRUCTION describing how to change it. Apply the instruction to the selected text. Rules:
- Output ONLY the edited text, ready to replace the selection exactly. No preamble, no commentary, no surrounding quotes.
- Keep everything the instruction does not ask to change: content, meaning, formatting, line breaks.
- Never use em dashes or en dashes anywhere. Use a period, comma, or colon instead.
- If the instruction is not an edit request, output the original text unchanged.
"""

// Code-only voice edits (v8.23). The AI transports handle arbitrary
// instructions, but the everyday ones are exactly the shapes the local
// transforms already produce, so a missing key or a dead proxy no longer
// means the feature does nothing at all. Returns nil for anything it cannot
// do FAITHFULLY: pasting a wrong guess over someone's selection is worse
// than pasting nothing, which is the standing rule for this mode.
func localCommandEdit(selection: String, instruction: String) -> String? {
    let i = instruction.lowercased()
    func has(_ patterns: [String]) -> Bool {
        patterns.contains { i.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }
    if has(["upper ?case", "all caps"]) { return selection.uppercased() }
    if has(["lower ?case"]) { return selection.lowercased() }
    if has(["summarize", "summarise", "summary"]) { return localSummarize(selection) }
    if has(["agent brief", "coding brief", "turn (?:this|it) into a brief"]) { return localAgentBrief(selection) }
    if has(["expand", "more detail", "flesh (?:this |it )?out"]) { return localExpand(selection) }
    if has(["clean (?:this |it )?up", "fix (?:the )?grammar", "fix (?:the )?punctuation",
            "fix (?:the )?spelling", "professional", "polish", "tidy", "proofread",
            "remove (?:the )?filler"]) { return localProfessional(selection) }
    return nil
}

func commandEdit(selection: String, instruction: String) -> String? {
    let payload = "SELECTED TEXT:\n\(selection)\n\nINSTRUCTION:\n\(instruction)"
    let timeout = max(30.0, Double(selection.count) / 40.0)
    var out: String?
    out = polishViaProxy(payload, timeout: timeout, mode: "command")
    if out == nil, cfg.polishKey.hasPrefix("gsk_") { out = polishViaGroq(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
    else if out == nil, !cfg.polishKey.isEmpty { out = polishViaAPI(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
    if out == nil { out = polishViaClaudeCLI(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
    if out == nil, let local = localCommandEdit(selection: selection, instruction: instruction) {
        log("· command edit handled in code (no AI needed)")
        out = local
    }
    guard let t = out?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
    let lower = t.lowercased()
    if lower.hasPrefix("i can't") || lower.hasPrefix("i cannot") || lower.hasPrefix("i'm sorry") { return nil }
    return t
}

// ===================== Polish choice popup =====================
// Ask-first UI for the prompt-polish: after a qualifying dictation, a floating
// pill offers Summarize (AI rewrite) or Keep the Same (raw transcript). The
// panel is non-activating — clicking a button never moves focus, so the paste
// still lands in the app being dictated into. An unanswered panel resolves to
// Keep the Same after cfg.polishAskTimeout so a walked-away dictation still pastes.
private final class ClickThroughButton: NSButton {
    // First click must land even though the accessory app is never active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ChoicePanel: NSObject {
    private static var current: ChoicePanel?

    private let panel: NSPanel
    private var onSummarize: (() -> Void)?
    private var onProfessional: (() -> Void)?
    private var onKeep: (() -> Void)?
    private var timeoutWork: DispatchWorkItem?

    static func show(transcript: String, onSummarize: @escaping () -> Void,
                     onProfessional: @escaping () -> Void, onKeep: @escaping () -> Void) {
        // One decision on screen at a time: an unanswered panel resolves as
        // Keep (the no-surprise choice) before the next transcript replaces it.
        current?.resolve(choice: "keep", auto: "superseded by a newer transcript")
        let cp = ChoicePanel(transcript: transcript, onSummarize: onSummarize,
                             onProfessional: onProfessional, onKeep: onKeep)
        current = cp
        cp.present()
    }

    private init(transcript: String, onSummarize: @escaping () -> Void,
                 onProfessional: @escaping () -> Void, onKeep: @escaping () -> Void) {
        self.onSummarize = onSummarize
        self.onProfessional = onProfessional
        self.onKeep = onKeep

        let w: CGFloat = 560, h: CGFloat = 118
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 0.92).cgColor
        root.layer?.cornerRadius = 16

        let words = transcript.split(separator: " ").count
        let title = NSTextField(labelWithString: "Transcript ready · \(words) words")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        title.frame = NSRect(x: 18, y: h - 30, width: w - 220, height: 18)
        root.addSubview(title)

        let hint = NSTextField(labelWithString: "keeps as spoken in \(Int(cfg.polishAskTimeout))s")
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        hint.alignment = .right
        hint.frame = NSRect(x: w - 210, y: h - 29, width: 192, height: 16)
        root.addSubview(hint)

        let preview = NSTextField(labelWithString: String(transcript.prefix(180)))
        preview.font = .systemFont(ofSize: 12, weight: .regular)
        preview.textColor = NSColor(calibratedWhite: 0.65, alpha: 1)
        preview.frame = NSRect(x: 18, y: 46, width: w - 36, height: 34)
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        root.addSubview(preview)

        let summarize = ClickThroughButton(title: "Summarize", target: nil, action: #selector(summarizeClicked))
        summarize.bezelStyle = .rounded
        summarize.frame = NSRect(x: w - 130, y: 10, width: 112, height: 30)
        root.addSubview(summarize)

        let pro = ClickThroughButton(title: "Professional", target: nil, action: #selector(professionalClicked))
        pro.bezelStyle = .rounded
        pro.frame = NSRect(x: w - 254, y: 10, width: 116, height: 30)
        root.addSubview(pro)

        let keep = ClickThroughButton(title: "Keep the Same", target: nil, action: #selector(keepClicked))
        keep.bezelStyle = .rounded
        keep.frame = NSRect(x: w - 386, y: 10, width: 124, height: 30)
        root.addSubview(keep)

        p.contentView = root
        panel = p
        super.init()
        summarize.target = self
        pro.target = self
        keep.target = self
    }

    private func present() {
        // Same placement rule as the recording HUD: bottom-center of the screen
        // the mouse is on (NSScreen.main is just the primary for an accessory app).
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - panel.frame.width / 2, y: f.minY + 40,
                                  width: panel.frame.width, height: panel.frame.height), display: true)
        }
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in
            self?.resolve(choice: "keep", auto: "no answer in \(Int(cfg.polishAskTimeout))s")
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.polishAskTimeout, execute: work)
    }

    @objc private func summarizeClicked() { resolve(choice: "summarize", auto: nil) }
    @objc private func professionalClicked() { resolve(choice: "professional", auto: nil) }
    @objc private func keepClicked() { resolve(choice: "keep", auto: nil) }

    private func resolve(choice: String, auto: String?) {
        guard onSummarize != nil || onKeep != nil else { return }   // already resolved
        timeoutWork?.cancel(); timeoutWork = nil
        panel.orderOut(nil)
        if ChoicePanel.current === self { ChoicePanel.current = nil }
        if let auto = auto { log("· choice popup auto-kept raw — \(auto)") }
        else { log("· choice: \(choice)") }
        let action: (() -> Void)?
        switch choice {
        case "summarize":    action = onSummarize
        case "professional": action = onProfessional
        default:             action = onKeep
        }
        onSummarize = nil; onProfessional = nil; onKeep = nil
        action?()
    }
}

// Run whisper-cli with a hard watchdog so a runaway decode can never wedge
// the tool. Returns the raw transcript, or nil on failure/timeout.
// Where a decode is allowed to run (v8.18). Queue-confined: ChunkEngine sets
// this around its synchronous transcribe calls on the serial ptt.chunks queue,
// so there is no cross-thread mutation. Everything else rides the .auto
// default.
//   .localOnly      — speculative pre-decodes: they fire every ~2s during
//                     pauses and would queue-starve the single cloud decoder
//                     (the 08-07 "slow asf" root cause #2). Local spec hits
//                     also make stops instant with zero cloud wait.
//   .cloudPreferred — chunk decodes: they run while the recording is still
//                     going, so cloud latency is invisible.
//   .auto           — tails / whole files / CLI hooks: cloud and local RACE
//                     and the fastest answer pastes, so the stop wait is
//                     never worse than local, and every race logs both times
//                     as live comparison telemetry.
enum DecodeRoute { case auto, cloudPreferred, localOnly }
var decodeRoute: DecodeRoute = .auto

func runWhisper(on wavPath: String, txtBase: String) -> String? {
    try? FileManager.default.removeItem(atPath: txtBase + ".txt")

    // Timeout scaled to clip length: turbo transcribes many× realtime, so
    // 2× duration + 60s of slack is generous. No fixed cap — duration is
    // already bounded by the auto-stop, and a 45-min meeting's decode
    // (with entropy-fallback re-decodes) must never be killed mid-flight.
    let wavBytes = (try? FileManager.default.attributesOfItem(atPath: wavPath)[.size] as? Int) ?? 0
    let duration = Double(wavBytes) / 32_000.0   // 16kHz mono s16 = 32kB/s
    let timeout = max(60.0, duration * 2 + 60)

    // Denoise + normalize first; decode the conditioned clip if ffmpeg succeeded,
    // else fall back to the raw capture. Temp file is removed after the decode.
    let ppWav = preprocessAudio(wavPath, duration: duration)
    let decodeWav = ppWav ?? wavPath
    defer { if let pp = ppWav { try? FileManager.default.removeItem(atPath: pp) } }
    if ppWav != nil { log("♪ conditioned audio (\(cfg.callMode ? "call" : "normal") chain) before decode") }

    // Cloud eligibility is shared by every route. Conditioning already
    // happened client-side above, and the engine's launch VAD gate (0.15)
    // equals the lowest mode gate, so all modes may ride the cloud.
    let cloudTimeout = max(25.0, duration * 1.5 + 15)
    let cloudEligible = cfg.cloud && !cfg.licenseKey.isEmpty && licenseValid

    // Customer builds ship with no local decode model on purpose: the model that
    // produces a transcript stays on the engine, which is what makes access
    // something we can grant and revoke. Recomputed per decode rather than read
    // from a file-scope global, so this can never depend on global init order.
    let canDecodeLocally = FileManager.default.fileExists(atPath: WHISPER)
        && FileManager.default.fileExists(atPath: MODEL)
    if !canDecodeLocally {
        guard cloudEligible else {
            log("‼️ no transcription available: the engine is unreachable or this license is not active, and this build has no local model")
            return nil
        }
        // No local side means there is nothing to race. Going straight to the
        // engine also avoids spawning a whisper-cli that can only fail.
        if let text = runWhisperViaCloud(wav: decodeWav, timeout: cloudTimeout) {
            log("☁ cloud engine decode")
            return text
        }
        log("‼️ engine did not answer within \(Int(cloudTimeout))s and there is no local model to fall back to")
        return nil
    }

    switch decodeRoute {
    case .localOnly:
        return runWhisperLocalPath(decodeWav: decodeWav, txtBase: txtBase,
                                   timeout: timeout, duration: duration)

    case .cloudPreferred:
        if cloudEligible, let text = runWhisperViaCloud(wav: decodeWav, timeout: cloudTimeout) {
            log("☁ cloud engine decode")
            return text
        }
        if cloudEligible { log("⚠️ cloud engine not answering — using local decode") }
        return runWhisperLocalPath(decodeWav: decodeWav, txtBase: txtBase,
                                   timeout: timeout, duration: duration)

    case .auto:
        guard cloudEligible else {
            return runWhisperLocalPath(decodeWav: decodeWav, txtBase: txtBase,
                                       timeout: timeout, duration: duration)
        }
        // RACE cloud vs local; fastest non-empty answer pastes. The loser
        // keeps running detached and only contributes its timing to the log.
        // Same model + same decode flags on both sides, so quality is
        // equivalent whichever wins.
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var winner: String?
        var winnerSrc = ""
        var times = [String: Double]()
        let t0 = Date()
        let jobs: [(String, () -> String?)] = [
            ("cloud", { runWhisperViaCloud(wav: decodeWav, timeout: cloudTimeout) }),
            ("local", { runWhisperLocalPath(decodeWav: decodeWav, txtBase: txtBase,
                                            timeout: timeout, duration: duration) }),
        ]
        for (name, job) in jobs {
            DispatchQueue.global(qos: .userInitiated).async {
                let r = job()
                let dt = Date().timeIntervalSince(t0)
                lock.lock()
                times[name] = dt
                if winner == nil, let r = r, !r.isEmpty { winner = r; winnerSrc = name }
                lock.unlock()
                sem.signal()
            }
        }
        // The first signal can be a failure — wait again for the other side
        // before giving up. Both nil = caller falls back exactly as before.
        _ = sem.wait(timeout: .now() + timeout + 5)
        lock.lock(); var text = winner; var src = winnerSrc; lock.unlock()
        if text == nil {
            _ = sem.wait(timeout: .now() + timeout + 5)
            lock.lock(); text = winner; src = winnerSrc; lock.unlock()
        }
        lock.lock()
        let cloudT = times["cloud"].map { String(format: "%.1fs", $0) } ?? "dnf"
        let localT = times["local"].map { String(format: "%.1fs", $0) } ?? "dnf"
        lock.unlock()
        guard let final = text else { return nil }
        log("⚡ decode race: \(src) won (cloud \(cloudT) · local \(localT))")
        return final
    }
}

// The pre-cloud decode stack, verbatim: resident server first, whisper-cli
// second. Extracted so the routes above can reuse it; behavior unchanged.
func runWhisperLocalPath(decodeWav: String, txtBase: String,
                         timeout: Double, duration: Double) -> String? {
    // Resident server first (call + whisper modes excepted: both need a lower
    // VAD gate than the server's launch-time threshold). Any failure falls
    // through to the CLI.
    if cfg.useServer, !cfg.callMode, !cfg.whisperMode {
        if let text = runWhisperViaServer(wav: decodeWav, timeout: timeout) {
            return text
        }
        log("⚠️ whisper-server not answering — falling back to whisper-cli (slower)")
    }

    let p = Process()
    p.executableURL = URL(fileURLWithPath: WHISPER)
    var args = ["-m", MODEL, "-f", decodeWav, "-l", cfg.language,
                "-nt", "-otxt", "-of", txtBase,
                // anti-hallucination + accuracy
                "-mc", "128",            // just enough context for the ~100-token vocab
                                         // prompt (truncates silently if under it); small
                                         // enough to starve repeat cascades
                "-et", "2.8",            // fail repetitive decodes -> retry at higher temp
                "-bs", "5", "-bo", "5",  // beam search
                "-sns",                  // suppress non-speech tokens
                "--prompt", effectivePrompt(), "--carry-initial-prompt"]
    if FileManager.default.fileExists(atPath: VAD_MODEL) {
        // VAD trims silence — and keeps the normalizer's amplified room-tone from
        // becoming hallucinated text — but at high thresholds it also drops quiet
        // words. Call mode pushes the gate down since ducked speech is marginal;
        // whisper mode pushes it further since whispers barely clear the floor.
        let vt = cfg.whisperMode ? min(cfg.vadThreshold, 0.15)
               : cfg.callMode ? min(cfg.vadThreshold, 0.2) : cfg.vadThreshold
        args += ["--vad", "-vm", VAD_MODEL, "-vt", String(vt)]
    }
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("!! whisper error: \(error)"); return nil }

    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
        if let p = p, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }
    p.waitUntilExit()
    // Watchdog kill arrives as SIGTERM/SIGKILL — no cross-thread flag needed.
    if p.terminationReason == .uncaughtSignal {
        log("!! whisper watchdog: killed after \(Int(timeout))s (clip \(Int(duration))s)")
        return nil
    }
    return try? String(contentsOfFile: txtBase + ".txt", encoding: .utf8)
}

// ===================== Rolling transcription (chunk cache) =====================
// The fix for "a 14-minute ramble takes 2 minutes to paste": while the recording
// is still running, audio that is already FINISHED is cut at natural pauses
// (~every chunkSeconds) and transcribed in the background with the exact same
// full-quality pipeline (preprocess + large model + VAD + vocab prompt). By the
// time the user taps stop, everything but the tail is already text — the paste
// waits only for the last chunk, a few seconds, no matter how long they talked.
//
// Safety: cuts happen only inside a detected pause (silence-seek over the raw
// PCM), so words are never split; if no pause shows up the cut is deferred to
// the next pass. Any decode failure abandons the cache and the stop falls back
// to the old whole-file decode — worst case is exactly the previous behavior.
// Like CaptionEngine, ALL state is confined to one serial queue and a generation
// token keeps late work from leaking across sessions. Decodes run ON the queue,
// which serializes them and makes finish() naturally wait for in-flight chunks.
final class ChunkEngine {
    private let queue = DispatchQueue(label: "ptt.chunks", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var specTimer: DispatchSourceTimer?
    private var generation = 0
    private var wavPath = ""
    private var dataOffset: UInt64?
    private var lastCutByte: UInt64 = 0     // relative to the WAV data chunk, even-aligned
    private var texts: [String] = []
    private var chunkIndex = 0
    private var failed = false
    private var sessionN = 0
    // Speculative tail: when he goes quiet mid/end-of-dictation, the un-cut tail
    // is decoded DURING the pause — if he then taps stop (the usual pattern),
    // the transcript is already done and the paste is near-instant. Resuming
    // speech just invalidates the guess (range mismatch at finish).
    private var specText: String?
    private var specFrom: UInt64 = 0
    private var specTo: UInt64 = 0
    private var specArmed = true            // one speculative decode per pause
    // v8.8: the moment a spec pass lands, the FULL transcript-so-far exists
    // (committed chunks + the just-decoded tail). Hand it up so the rewrite
    // can pre-run during the same pause — predictive preload while talking.
    var onSpecTranscript: ((String) -> Void)?

    // Injected so --chunk-sim and the daemon share the pipeline verbatim.
    var transcribe: (String, String) -> String? = { runWhisper(on: $0, txtBase: $1) }

    var enabled: Bool { cfg.chunkSeconds >= 20 }

    func start(wav: String, session: Int) {
        guard enabled else { return }
        queue.async {
            self.generation += 1
            let gen = self.generation
            self.reset(wav: wav, session: session)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + cfg.chunkSeconds, repeating: cfg.chunkSeconds)
            t.setEventHandler { [weak self] in
                guard let self = self, gen == self.generation, !self.failed else { return }
                self.cut()
            }
            t.resume()
            self.timer = t
            let st = DispatchSource.makeTimerSource(queue: self.queue)
            st.schedule(deadline: .now() + 2.0, repeating: 2.0)
            st.setEventHandler { [weak self] in
                guard let self = self, gen == self.generation, !self.failed else { return }
                self.specPass()
            }
            st.resume()
            self.specTimer = st
        }
    }

    func cancel() {
        queue.async {
            self.generation += 1
            self.timer?.cancel(); self.timer = nil
            self.specTimer?.cancel(); self.specTimer = nil
        }
    }

    // Called after capturer.stop() (file finalized). Decodes the tail, joins the
    // cache in order, and hands back the raw transcript — or nil if there is no
    // usable cache (short clip, disabled, or a failed chunk), in which case the
    // caller must run the old whole-file decode.
    func finish(completion: @escaping (String?) -> Void) {
        queue.async {
            self.generation += 1
            self.timer?.cancel(); self.timer = nil
            self.specTimer?.cancel(); self.specTimer = nil
            // A valid speculative cache lets even a SHORT (chunkless) clip skip
            // the whole-file decode — the tail guess covers [0, stop).
            guard self.chunkIndex > 0 || self.specText != nil, !self.failed,
                  let off = self.resolveOffset(),
                  let fh = FileHandle(forReadingAtPath: self.wavPath) else { completion(nil); return }
            let size = fh.seekToEndOfFile()
            let usable = size > off ? (size - off) & ~1 : 0
            var parts = self.texts
            if usable > self.lastCutByte + 6400 {        // >0.2s of audio after the last cut
                // Speculative hit: tail already decoded during the pre-stop
                // pause, and only quiet room-tone (≤3s) arrived since — use it
                // (whisper's VAD would have trimmed that silence anyway).
                if let spec = self.specText, self.specFrom == self.lastCutByte,
                   usable >= self.specTo, usable - self.specTo <= UInt64(3 * 32000),
                   rangeRMS(fh: fh, dataOff: off, from: self.specTo, to: usable) < 300 {
                    fh.closeFile()
                    log("⚡ tail was pre-decoded — zero decode wait at stop")
                    parts.append(spec)
                } else {
                    let len = usable - self.lastCutByte
                    fh.seek(toFileOffset: off + self.lastCutByte)
                    let pcm = fh.readData(ofLength: Int(len))
                    fh.closeFile()
                    let base = "/tmp/ptt_chunk_\(self.sessionN)_tail"
                    writeWav16kMono(pcm, to: base + ".wav")
                    let t0 = Date()
                    let raw = self.transcribe(base + ".wav", base)
                    try? FileManager.default.removeItem(atPath: base + ".wav")
                    try? FileManager.default.removeItem(atPath: base + ".txt")
                    guard let raw = raw else { completion(nil); return }
                    log("· tail decoded · \(Int(Double(len) / 32000))s → \(String(format: "%.1f", -t0.timeIntervalSinceNow))s (\(self.chunkIndex) chunk\(self.chunkIndex == 1 ? "" : "s") pre-cached)")
                    parts.append(raw)
                }
            } else {
                fh.closeFile()
            }
            completion(parts.joined(separator: "\n"))
        }
    }

    // Test hooks for --chunk-sim/--spec-sim: drive the pipeline without a timer/mic.
    func simStart(wav: String, session: Int) { queue.sync { reset(wav: wav, session: session) } }
    func simFire() { queue.sync { cut() } }
    func simSpec() { queue.sync { specPass() } }

    private func reset(wav: String, session: Int) {
        wavPath = wav; sessionN = session
        dataOffset = nil; lastCutByte = 0
        texts = []; chunkIndex = 0; failed = false
        specText = nil; specArmed = true
        timer?.cancel(); timer = nil
        specTimer?.cancel(); specTimer = nil
    }

    // One speculative pass (2s cadence while recording): if the last ~1.6s is
    // quiet relative to the recent speech level, decode the whole un-cut tail
    // now, so a stop tap right after finds the transcript already made.
    private func specPass() {
        guard cfg.speculative, let off = resolveOffset(),
              let fh = FileHandle(forReadingAtPath: wavPath) else { return }
        defer { fh.closeFile() }
        let size = fh.seekToEndOfFile()
        guard size > off else { return }
        let usable = (size - off) & ~1
        guard usable > lastCutByte else { return }
        let pending = usable - lastCutByte
        guard pending >= 32000 else { return }                     // ≥1s of tail
        let tailFrom = (usable - min(pending, UInt64(51200))) & ~1 // last 1.6s
        let refFrom = (usable - min(pending, UInt64(10 * 32000))) & ~1
        let tailRms = rangeRMS(fh: fh, dataOff: off, from: tailFrom, to: usable)
        let refRms = rangeRMS(fh: fh, dataOff: off, from: refFrom, to: usable)
        if tailRms >= max(120, refRms * 0.25) { specArmed = true; return }   // still talking
        guard specArmed else { return }                             // one shot per pause
        specArmed = false
        fh.seek(toFileOffset: off + lastCutByte)
        let pcm = fh.readData(ofLength: Int(pending))
        let base = "/tmp/ptt_chunk_\(sessionN)_spec"
        writeWav16kMono(pcm, to: base + ".wav")
        let t0 = Date()
        // Speculative guesses stay LOCAL: they fire every ~2s during pauses
        // and would queue-starve the single cloud decoder; a local spec hit
        // also means a zero-wait stop with no cloud round trip at all.
        decodeRoute = .localOnly
        let raw = transcribe(base + ".wav", base)
        decodeRoute = .auto
        try? FileManager.default.removeItem(atPath: base + ".wav")
        try? FileManager.default.removeItem(atPath: base + ".txt")
        guard let text = raw else { return }
        specText = text; specFrom = lastCutByte; specTo = usable
        log("· tail pre-decoded during pause · \(Int(pending / 32000))s → \(String(format: "%.1f", -t0.timeIntervalSinceNow))s")
        onSpecTranscript?((texts + [text]).joined(separator: "\n"))
    }

    private func resolveOffset() -> UInt64? {
        if dataOffset == nil { dataOffset = findWavDataOffset(wavPath) ?? 4096 }
        return dataOffset
    }

    // One pass: if at least ~¾ of a chunk of NEW audio exists, find a pause near
    // the end of it, slice [lastCutByte, pause) to a temp wav, and decode it.
    private func cut() {
        guard let off = resolveOffset(),
              let fh = FileHandle(forReadingAtPath: wavPath) else { return }
        defer { fh.closeFile() }
        let size = fh.seekToEndOfFile()
        guard size > off else { return }
        let usable = (size - off) & ~1
        guard usable > lastCutByte else { return }
        let chunkBytes = UInt64(cfg.chunkSeconds * 32000)
        let pending = usable - lastCutByte
        guard pending >= chunkBytes * 3 / 4 else { return }   // timer jitter / writer lag

        var cutByte: UInt64
        if let c = quietCutPoint(fh: fh, dataOff: off, from: lastCutByte, to: usable,
                                 lookback: UInt64(8 * 32000)) {
            cutByte = c
        } else if pending >= chunkBytes * 3 {
            // No pause for 3 chunk-lengths of continuous speech — cap the tail
            // cost with a hard cut. Whisper loses at most a word at the seam.
            cutByte = usable
            log("· chunk \(chunkIndex + 1): no pause in \(Int(pending / 32000))s — hard cut")
        } else {
            return                                            // wait for a real pause
        }

        let len = cutByte - lastCutByte
        fh.seek(toFileOffset: off + lastCutByte)
        let pcm = fh.readData(ofLength: Int(len))
        let base = "/tmp/ptt_chunk_\(sessionN)_\(chunkIndex)"
        writeWav16kMono(pcm, to: base + ".wav")
        let t0 = Date()
        // Chunks decode while the recording is still running, so cloud
        // latency is invisible here — no race needed, local is the fallback.
        decodeRoute = .cloudPreferred
        let raw = transcribe(base + ".wav", base)
        decodeRoute = .auto
        try? FileManager.default.removeItem(atPath: base + ".wav")
        try? FileManager.default.removeItem(atPath: base + ".txt")
        if let raw = raw {
            texts.append(raw)
            chunkIndex += 1
            lastCutByte = cutByte
            specText = nil          // cache was for the pre-cut tail — stale now
            log("· chunk \(chunkIndex) cached · \(Int(Double(len) / 32000))s → \(String(format: "%.1f", -t0.timeIntervalSinceNow))s decode")
        } else {
            // One bad chunk poisons the cache — stop burning cycles; the stop
            // will decode the whole file exactly as the pre-chunking build did.
            failed = true
            timer?.cancel(); timer = nil
            log("⚠️ chunk decode failed — cache abandoned, will full-decode at stop")
        }
    }
}

// ===================== Core =====================
final class Dictation: NSObject {
    let capturer = AudioCapturer()
    var recording = false
    var sessionN = 0
    var currentWav = ""
    var lastSavedN = 0              // newest session kept as /tmp/ptt_last.wav
    var autoStop: DispatchWorkItem?
    let captions = CaptionEngine()
    let chunks = ChunkEngine()

    // Clipboard bookkeeping for insert(): survives overlapping inserts from
    // concurrent jobs without "restoring" our own previous transcript.
    // A full snapshot, not just the plain-text flavor. Reading only .string
    // returned nil whenever the user had copied an image, a file, or rich text,
    // and the restore below then cleared the pasteboard and put nothing back —
    // so dictating once silently destroyed a copied screenshot.
    var savedItems: [NSPasteboardItem] = []
    var lastInsertChangeCount = -1

    // Solo-press tracking for the trigger key.
    var triggerDown = false
    var soloCandidate = false       // true while the current press has seen no other key
    var cmdCandidate = false        // Option was held at press time -> command mode tap
    var commandSelection: String?   // non-nil while a command-mode recording is in flight
    var instantFinish = false       // v8.8: next stop is push-to-live (never waits on the AI)

    // ---- Trigger key state machine (driven by the global event monitor) ----

    func triggerKeyDown(flags: NSEvent.ModifierFlags) {
        triggerDown = true
        // Not a solo press if any other modifier is already held (aborted chords,
        // both Cmd keys, remapper-latched modifiers). Option alone is special:
        // Option-held + Right-⌘ tap = command mode (edit the selection by voice).
        let option = flags.contains(.option)
        let othersHeld = flags.contains(.shift) || flags.contains(.control)
            || (cfg.hotkey != 55 && (flags.rawValue & LEFT_CMD_BIT) != 0)
        soloCandidate = !othersHeld && !option
        cmdCandidate = !othersHeld && option && !recording
    }

    // Released: if nothing else was pressed while it was down, toggle. No time limit.
    // (Command tap: release Right-⌘ BEFORE Option — dropping Option first reads
    // as chord activity and vetoes, same as any other modifier.)
    func triggerKeyUp() {
        let wasSolo = soloCandidate
        let wasCmd = cmdCandidate
        triggerDown = false
        soloCandidate = false
        cmdCandidate = false
        if wasCmd { startCommandMode(); return }
        guard wasSolo else { return }
        // Secure input hides keyDowns from us, so keyboard-chord detection is
        // blind while it's active. Brady's Terminal keeps Secure Keyboard Entry
        // ON permanently AND is where he dictates, so blocking here would kill
        // the primary use case — log the degraded mode and toggle anyway.
        // (Mouse-chord + held-modifier vetoes still work; a false start is
        // bounded by the auto-stop and the visible HUD/menu-bar state.)
        if IsSecureEventInputEnabled() {
            log("· secure input active — keyboard-chord veto degraded, toggling anyway")
        }
        toggle()
    }

    // Any OTHER key/modifier while the trigger is held = it's a chord (Right-⌘
    // used as a real modifier) — never toggles.
    func otherKeyActivity() {
        if triggerDown { soloCandidate = false; cmdCandidate = false }
    }

    // Post a Cmd+<key> keystroke into the focused app (same mechanism insert()
    // uses for Cmd-V).
    private func postCmdKey(_ vk: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Option+Right-⌘: grab the selection via a synthesized Cmd-C (clipboard is
    // restored right after — the grab is internal), then record the instruction.
    // No selection -> Basso + log, nothing starts, nothing is ever pasted.
    func startCommandMode() {
        guard !recording else { return }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        // Full snapshot, and restored on EVERY exit path below. The old code kept
        // only the plain-text flavor and skipped the restore entirely on the
        // no-selection path, so an aborted command-mode grab left our synthesized
        // copy sitting in the user's clipboard.
        let saved = snapshotPasteboard(pb)
        let restore = {
            guard !saved.isEmpty, pb.changeCount != before else { return }
            pb.clearContents()
            pb.writeObjects(saved)
        }
        postCmdKey(8)   // kVK_ANSI_C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, !self.recording else { restore(); return }
            guard pb.changeCount != before, let sel = pb.string(forType: .string),
                  !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("✕ command mode: no text selected — highlight text, then Option+Right ⌘")
                playSound("Basso")
                restore()
                return
            }
            restore()
            self.commandSelection = sel
            log("🎯 command mode: \(sel.count) chars selected — speak the edit, tap Right ⌘ to apply")
            self.startRecording()
            ui.setCaption("🎯 Speak the edit for the selected text…")
        }
    }

    // A tap now ALWAYS does something: starts a recording or stops the current
    // one. Transcription of earlier clips runs in the background — no more
    // "busy" lockout between recordings.
    func toggle() {
        if recording {
            stopAndTranscribe()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard licenseValid else {
            log("✕ recording blocked — license inactive. Manage it at nesso.tech")
            playSound("Basso")
            return
        }
        // AVAudioEngine.start() can block in audio-server XPC while TCC mic
        // authorization is unresolved (fresh binary = fresh TCC identity) —
        // never start it unless we're already authorized.
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        guard auth == .authorized else {
            log("⚠️ mic not authorized — requesting access; grant ptt-dictate in System Settings ▸ Privacy & Security ▸ Microphone, then tap Right ⌘ again")
            playSound("Basso")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log(granted ? "✓ Microphone granted — tap Right ⌘ to dictate"
                            : "⚠️ Microphone DENIED — enable ptt-dictate in System Settings ▸ Privacy & Security ▸ Microphone")
            }
            return
        }
        sessionN += 1
        currentWav = "/tmp/ptt_rec_\(sessionN).wav"
        try? FileManager.default.removeItem(atPath: currentWav)
        let started = capturer.start(
            path: currentWav, preference: cfg.inputDevice,
            onSwap: { name in log("⚠️ first input produced no audio — switched to \(name)") },
            onDead: {
                log("‼️ no audio from any microphone — open System Settings ▸ Sound ▸ Input, pick a working mic, and confirm ptt-dictate has Microphone access")
                playSound("Basso")
                ui.setCaption("⚠️ no mic audio — check Sound ▸ Input")
            })
        guard started else {
            // AVCaptureSession couldn't open any input — genuinely rare now (it's
            // immune to the -10868 wedge). Stay alive and point at Sound settings.
            try? FileManager.default.removeItem(atPath: currentWav)
            playSound("Basso")
            ui.setCaption("⚠️ couldn't start mic — check Sound ▸ Input")
            log("‼️ AVCapture couldn't start on any input — check System Settings ▸ Sound ▸ Input")
            return
        }
        recording = true
        log("● recording… (session \(sessionN)) · mic=\(capturer.deviceName)")
        playSound("Tink")
        ui.recordingStarted()
        captions.start(wav: currentWav)
        chunks.start(wav: currentWav, session: sessionN)
        let stopper = DispatchWorkItem { [weak self] in
            guard let self = self, self.recording else { return }
            log("⏱ auto-stop after \(Int(cfg.maxRecordSeconds))s — mic was left on")
            playSound("Submarine")
            self.stopAndTranscribe()
        }
        autoStop = stopper
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.maxRecordSeconds, execute: stopper)
    }

    // v8.8 push-to-live: stop NOW and deliver with zero AI wait — the pre-run
    // rewrite if it already finished, otherwise the raw transcript.
    func finishInstantly() {
        guard recording else { return }
        instantFinish = true
        stopAndTranscribe()
    }

    func cancelRecording() {
        guard recording else { return }
        recording = false
        instantFinish = false
        autoStop?.cancel(); autoStop = nil
        captions.stop()
        chunks.cancel()
        _ = capturer.stop()
        try? FileManager.default.removeItem(atPath: currentWav)
        commandSelection = nil
        ui.recordingStopped()
        log("✕ recording canceled — nothing transcribed")
        playSound("Bottle")
    }

    func stopAndTranscribe() {
        guard recording else { return }
        recording = false
        // Captured per-session: was this stop a push-to-live Finish?
        let instant = instantFinish
        instantFinish = false
        autoStop?.cancel(); autoStop = nil
        captions.stop()
        let snap = capturer.stop()
        ui.recordingStopped()
        let wav = currentWav
        let n = sessionN
        log("■ stopped, transcribing… (session \(n)) · \(String(format: "%.1f", Double(snap.bytes) / 32000.0))s captured, peak \(snap.peak)")
        playSound("Pop")
        // Distinguish a dead mic (no frames at all) from a live-but-silent room —
        // both yield an empty paste, but only the first is a fault worth flagging.
        if snap.frames == 0 {
            log("⚠️ session \(n) captured 0 audio frames — mic/permission problem, not your speech")
        } else if snap.peak < 80 {
            log("⚠️ session \(n) input was near-silent (peak \(snap.peak)) — were you speaking into \(snap.device)?")
        }
        ui.setBusy(+1)
        // Paste target decides polish: dictating into an AI app (Claude tab,
        // terminal, editor) gets the prompt rewrite; everything else pastes the
        // transcript as-is. Captured NOW — focus can move during transcription.
        let frontApp = (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "").lowercased()
        let aiTarget = cfg.polish && cfg.polishApps.lowercased().split(separator: ",")
            .contains { !$0.isEmpty && frontApp.contains($0.trimmingCharacters(in: .whitespaces)) }
        // Auto-Professional targets (Wispr-style tone-by-app): texting/email apps
        // get the professional rewrite with no popup and no click.
        let proTarget = cfg.polish && cfg.proApps.lowercased().split(separator: ",")
            .contains { !$0.isEmpty && frontApp.contains($0.trimmingCharacters(in: .whitespaces)) }
        // Mode clicked on the recording HUD (main thread, and so are we) —
        // captured NOW so a click during a long transcription can't retarget it.
        let hudMode = ui.selectedMode
        let pickedNow = ui.modePickedThisRecording
        // Command mode: consume the pending selection; this transcript is an
        // edit instruction, not a dictation.
        let cmdSelection = commandSelection
        commandSelection = nil
        // Paste + log + cleanup on main — the single exit for every path below.
        let finish: (String, String) -> Void = { [weak self] text, tag in
            DispatchQueue.main.async {
                if !text.isEmpty {
                    self?.insert(text)
                    logTranscript(text, tag: tag)
                    playSound("Glass")
                } else {
                    log("… empty transcription (session \(n))")
                    playSound("Basso")
                }
                ui.setBusy(-1)
                // Keep the most recent clip for forensics — jobs complete out of
                // session order, so only a NEWER session may take the slot.
                if let self = self, cfg.keepLastClip, n > self.lastSavedN {
                    try? FileManager.default.removeItem(atPath: "/tmp/ptt_last.wav")
                    try? FileManager.default.moveItem(atPath: wav, toPath: "/tmp/ptt_last.wav")
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                           ofItemAtPath: "/tmp/ptt_last.wav")
                    self.lastSavedN = n
                } else {
                    try? FileManager.default.removeItem(atPath: wav)
                }
                try? FileManager.default.removeItem(atPath: "/tmp/ptt_rec_\(n).txt")
            }
        }
        // v8.11: the rewrite modes are CODE, not a model — local, free, instant
        // by design. Because the transform completes in microseconds, a
        // push-to-live Finish delivers the exact same result as a normal stop:
        // the picked mode ALWAYS applies, never a raw paste because something
        // "wasn't ready". Preload is inherent.
        let runMode: (String, String) -> Void = { text, mode in
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                logTranscript(text, tag: " raw")
                finish(localModeTransform(text, mode: mode),
                       " ⌁\(String(format: "%.2f", -t0.timeIntervalSinceNow))s \(mode)")
            }
        }
        let summarize: (String) -> Void = { runMode($0, "summarize") }
        let professional: (String) -> Void = { runMode($0, "professional") }
        let agentBrief: (String) -> Void = { runMode($0, "agent") }
        let expandText: (String) -> Void = { runMode($0, "expand") }
        // Deliver, shared by both decode routes. Priority: command mode (the
        // transcript is an edit instruction for the captured selection) > spoken
        // "verbatim" escape > a mode clicked on the recording HUD (no popup, no
        // app gate — an explicit click means that delivery regardless of the
        // target app) > the AI-app ask/auto flow > auto-Professional apps > raw.
        let deliver: (String) -> Void = { rawText in
            var text = rawText
            if let sel = cmdSelection {
                guard !text.isEmpty else {
                    log("✕ command mode: empty instruction — selection left untouched")
                    finish("", "")
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let t0 = Date()
                    if let edited = commandEdit(selection: sel, instruction: text) {
                        logTranscript(text, tag: " cmd")
                        finish(edited, " 🎯\(String(format: "%.1f", -t0.timeIntervalSinceNow))s edit")
                    } else {
                        log("⚠️ command edit failed — nothing pasted, selection left untouched")
                        finish("", "")
                    }
                }
                return
            }
            if let r = text.range(of: "^(?i)verbatim[,.]?\\s*", options: .regularExpression) {
                text.removeSubrange(r)
                finish(text, "")
                return
            }
            if text.isEmpty { finish(text, ""); return }
            // Learned per-app mode: if no chip was clicked THIS recording and
            // this app has a clear habit (3+ picks, 60%+ one mode), the habit
            // wins over the sticky selection. An explicit pick always wins,
            // and explicit picks are what teach the habit in the first place.
            var mode = hudMode
            if !pickedNow, let learned = learnedModeFor(app: frontApp) {
                let lm = DeliverMode.fromConfig(learned)
                if lm != mode {
                    log("· learned mode for \(frontApp): \(lm.label) (your usual pick here)")
                    mode = lm
                }
            }
            switch mode {
            case .raw:          finish(text, ""); return
            case .summarize:    summarize(text); return
            case .professional: professional(text); return
            case .agent:        agentBrief(text); return
            case .expand:       expandText(text); return
            case .ask:          break
            }
            // No chip clicked — v8.3 default flow, no popup ever. Texting/email
            // apps keep the auto-Professional cleanup; everywhere else
            // DEFAULT_MODE decides (summarize unless configured otherwise).
            // Short clips paste raw: an LLM round-trip on a one-liner is pure
            // latency, and a one-liner has nothing to summarize.
            let words = text.split(separator: " ").count
            if !aiTarget, proTarget, words >= cfg.polishMinWords {
                log("· auto-professional (\(frontApp))")
                professional(text)
                return
            }
            guard cfg.polish, words >= cfg.polishMinWords else {
                finish(text, "")
                return
            }
            switch cfg.defaultMode {
            case "summarize":
                log("· default mode: summarize")
                summarize(text)
            case "professional":
                log("· default mode: professional")
                professional(text)
            case "normal":
                finish(text, "")
            case "agent":
                log("· default mode: agent brief")
                agentBrief(text)
            case "expand":
                log("· default mode: extend")
                expandText(text)
            default:   // "ask" — the pre-v8.3 popup/auto flow, AI apps only
                guard aiTarget else { finish(text, ""); return }
                // Push-to-live never opens a popup: grab the pre-run summarize
                // if it's ready, else the raw words. (summarize() handles both.)
                if instant { summarize(text); return }
                if cfg.polishAsk {
                    let t = text
                    DispatchQueue.main.async {
                        log("? transcript ready (session \(n)) — Summarize / Professional / Keep?")
                        ChoicePanel.show(transcript: t,
                                         onSummarize: { summarize(t) },
                                         onProfessional: { professional(t) },
                                         onKeep: { finish(t, "") })
                    }
                } else {
                    summarize(text)
                }
            }
        }
        // Rolling cache first: everything before the tail was transcribed while
        // still recording, so this returns in seconds. nil (short clip, chunking
        // off, or a failed chunk) = the whole-file decode, exactly as before.
        chunks.finish { joined in
            if let joined = joined {
                deliver(formatTranscript(joined))
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    deliver(runWhisper(on: wav, txtBase: "/tmp/ptt_rec_\(n)").map(formatTranscript) ?? "")
                }
            }
        }
    }

    // Insert text into the focused field via clipboard + Cmd-V, then restore clipboard.
    func insert(_ raw: String) {
        // Typography is applied at the last moment because only here do we
        // know the real paste target.
        let text = smartTypography(raw, bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        let pb = NSPasteboard.general
        // Only capture the "original" if the pasteboard isn't still holding OUR
        // previous transcript — otherwise overlapping inserts would "restore"
        // transcript A over the user's real clipboard content.
        if pb.changeCount != lastInsertChangeCount {
            savedItems = snapshotPasteboard(pb)
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let myChange = pb.changeCount
        lastInsertChangeCount = myChange

        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // 'v'
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        // Restore only if the pasteboard still holds OUR transcript (changeCount
        // unchanged) — a slow app reading late, or a newer copy/insert, wins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard pb.changeCount == myChange else { return }
            // Never clear without something to put back. An empty snapshot means
            // we could not read the original, and leaving our transcript on the
            // pasteboard is strictly better than handing the user an empty one.
            guard let items = self?.savedItems, !items.isEmpty else { return }
            pb.clearContents()
            pb.writeObjects(items)
        }
    }
}

// Deep-copies every flavor of every pasteboard item. Items read back from a
// pasteboard are owned by it and go invalid on clearContents(), so the data has
// to be copied into fresh items before anything is cleared.
func snapshotPasteboard(_ pb: NSPasteboard) -> [NSPasteboardItem] {
    guard let items = pb.pasteboardItems else { return [] }
    return items.map { old in
        let copy = NSPasteboardItem()
        for type in old.types {
            if let data = old.data(forType: type) { copy.setData(data, forType: type) }
        }
        return copy
    }
}

// ===================== Permissions =====================
@discardableResult
func ensureAccessibility() -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts = [promptKey: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    log(trusted
        ? "✓ Accessibility granted"
        : "⚠️ Accessibility NOT granted — System Settings ▸ Privacy & Security ▸ Accessibility, enable 'ptt-dictate', then relaunch.")
    return trusted
}

// ===================== CLI test modes =====================
// ptt-dictate --format-stdin            : read raw transcript on stdin, print formatted (no mic)
// ptt-dictate --transcribe-file <wav>   : run the full whisper+format pipeline, print (no mic)
// ptt-dictate --devices                 : list available input devices (no mic)
// ptt-dictate --mic-check [pref]        : record ~3s, report level + transcript (NEEDS mic grant)
let cliArgs = CommandLine.arguments
if cliArgs.count >= 2, cliArgs[1] == "--format-stdin" {
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(formatTranscript(input))
    exit(0)
}
if cliArgs.count >= 2, cliArgs[1] == "--polish-stdin" {
    // Feed a raw transcript through the AI prompt-polish pass (no mic/daemon).
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let polished = polishForAI(formatTranscript(input)) {
        print(polished)
    } else {
        print("POLISH FAILED — daemon would paste the raw transcript")
        exit(1)
    }
    exit(0)
}
if cliArgs.count >= 2, cliArgs[1] == "--polish-text-stdin" {
    // Feed a raw transcript through the PROFESSIONAL (texting/email) rewrite.
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if let polished = polishForText(formatTranscript(input)) {
        print(polished)
    } else {
        print("PRO POLISH FAILED — daemon would paste the raw transcript")
        exit(1)
    }
    exit(0)
}
if cliArgs.count >= 3, cliArgs[1] == "--local-mode" {
    // Feed a transcript through the OFFLINE code transform for a mode
    // (summarize | professional | agent | expand). No network, no daemon.
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(localModeTransform(formatTranscript(input), mode: cliArgs[2]))
    exit(0)
}
if cliArgs.count >= 3, cliArgs[1] == "--local-command" {
    // Feed a selection (stdin) plus a spoken instruction through the OFFLINE
    // command-edit path. Prints nothing and exits 1 when code cannot do the
    // edit faithfully, which is the same "paste nothing" contract the mode
    // itself follows. No network, no daemon.
    let sel = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let out = localCommandEdit(selection: sel.trimmingCharacters(in: .whitespacesAndNewlines),
                                     instruction: cliArgs[2]) else { exit(1) }
    print(out)
    exit(0)
}
if cliArgs.count >= 2, cliArgs[1] == "--devices" {
    for d in allInputDevices() {
        print("\(d.builtIn ? "[built-in]" : "          ") id=\(d.id)  \(d.name)")
    }
    let pref = cliArgs.count >= 3 ? cliArgs[2] : cfg.inputDevice
    print("→ preference \"\(pref)\" resolves to: " +
          resolveInputCandidates(pref).map { $0.name }.joined(separator: " → "))
    exit(0)
}
if cliArgs.count >= 2, cliArgs[1] == "--mic-check" {
    // End-to-end audio proof that does NOT need the daemon: pick the device, record
    // ~3s, report whether real samples arrived, then transcribe. Run this right
    // after re-granting Microphone to confirm capture works.
    let pref = cliArgs.count >= 3 ? cliArgs[2] : cfg.inputDevice
    let path = "/tmp/ptt_miccheck.wav"
    let cap = AudioCapturer()
    let started = cap.start(path: path, preference: pref,
        onSwap: { n in FileHandle.standardError.write("· switched to \(n)\n".data(using: .utf8)!) },
        onDead: { FileHandle.standardError.write("‼️ NO AUDIO from any input\n".data(using: .utf8)!) })
    guard started else { print("FAIL: capture could not start"); exit(1) }
    FileHandle.standardError.write("recording 3s — say something…\n".data(using: .utf8)!)
    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    let snap = cap.stop()
    print("device=\(snap.device)  frames=\(snap.frames)  peak=\(snap.peak)/32767  captured=\(String(format: "%.1f", Double(snap.bytes) / 32000.0))s")
    if snap.frames == 0 { print("RESULT: ✗ no audio frames — mic not delivering"); exit(2) }
    if snap.peak < 80 { print("RESULT: ⚠️ frames flowed but near-silent — speak louder / check input level") }
    if let raw = runWhisper(on: path, txtBase: "/tmp/ptt_miccheck") {
        print("transcript: \(formatTranscript(raw))")
    }
    try? FileManager.default.removeItem(atPath: "/tmp/ptt_miccheck.txt")
    print("RESULT: ✓ capture path works")
    exit(0)
}
final class AVTestCounter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var frames = 0
    func captureOutput(_ o: AVCaptureOutput, didOutput s: CMSampleBuffer, from c: AVCaptureConnection) {
        frames += CMSampleBufferGetNumSamples(s)
    }
}
if cliArgs.count >= 2, cliArgs[1] == "--av-test" {
    // Probe whether AVCaptureSession (a different HAL path than AVAudioEngine) can
    // capture while AVAudioEngine is -10868-wedged. If frames flow here, the daemon
    // can switch capture engines for a permanent, root-free fix.
    let session = AVCaptureSession()
    guard let dev = AVCaptureDevice.default(for: .audio) else { print("AVTEST: no audio device"); exit(1) }
    print("AVTEST device: \(dev.localizedName)")
    do {
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { print("AVTEST: cannot add input"); exit(1) }
        session.addInput(input)
    } catch { print("AVTEST: input error \(error.localizedDescription)"); exit(1) }
    let output = AVCaptureAudioDataOutput()
    let counter = AVTestCounter()
    output.setSampleBufferDelegate(counter, queue: DispatchQueue(label: "avtest"))
    guard session.canAddOutput(output) else { print("AVTEST: cannot add output"); exit(1) }
    session.addOutput(output)
    session.startRunning()
    print("AVTEST: session running=\(session.isRunning) — capturing 2s…")
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    session.stopRunning()
    let ok = counter.frames > 0
    print("AVTEST RESULT: frames=\(counter.frames) -> \(ok ? "✓ AVCaptureSession WORKS while AVAudioEngine is wedged" : "✗ also dead")")
    exit(ok ? 0 : 2)
}
if cliArgs.count >= 3, cliArgs[1] == "--transcribe-file" {
    let cliTxtBase = "/tmp/ptt_clitest_\(getpid())"
    guard let raw = runWhisper(on: cliArgs[2], txtBase: cliTxtBase) else {
        FileHandle.standardError.write("transcription failed\n".data(using: .utf8)!)
        exit(1)
    }
    print(formatTranscript(raw))
    try? FileManager.default.removeItem(atPath: cliTxtBase + ".txt")
    exit(0)
}
if cliArgs.count >= 3, cliArgs[1] == "--chunk-sim" {
    // Prove the rolling-chunk pipeline without a mic: replay an existing WAV as
    // if it were being recorded live — append its PCM to a growing file, firing
    // the chunk cutter after each simulated interval, then finish (tail decode +
    // join + format) and print the result. Compare against --transcribe-file.
    let src = cliArgs[2]
    guard let srcOff = findWavDataOffset(src), let sfh = FileHandle(forReadingAtPath: src) else {
        FileHandle.standardError.write("cannot read \(src)\n".data(using: .utf8)!); exit(1)
    }
    let total = (sfh.seekToEndOfFile() - srcOff) & ~1
    let sim = "/tmp/ptt_chunksim.wav"
    FileManager.default.createFile(atPath: sim, contents: wavHeader(dataBytes: UInt32(total)))
    guard let out = FileHandle(forWritingAtPath: sim) else { exit(1) }
    out.seekToEndOfFile()
    let engine = ChunkEngine()
    guard engine.enabled else { print("CHUNK-SIM: chunking disabled (CHUNK_SECONDS < 20)"); exit(1) }
    engine.simStart(wav: sim, session: 0)
    let step = UInt64(cfg.chunkSeconds * 32000) & ~1
    var done: UInt64 = 0
    while done < total {
        let take = min(step, total - done)
        sfh.seek(toFileOffset: srcOff + done)
        out.write(sfh.readData(ofLength: Int(take)))
        done += take
        if done < total { engine.simFire() }   // what's left after the last append is the tail
    }
    let sem = DispatchSemaphore(value: 0)
    var result: String?
    engine.finish { r in result = r; sem.signal() }
    sem.wait()
    try? FileManager.default.removeItem(atPath: sim)
    guard let r = result else { print("CHUNK-SIM: no cache built (clip shorter than a chunk, or a decode failed)"); exit(2) }
    print(formatTranscript(r))
    exit(0)
}
if cliArgs.count >= 3, cliArgs[1] == "--spec-sim" {
    // Prove the speculative-tail path without a mic: replay a WAV as a live
    // recording, append a 2.5s "pre-stop pause" of silence, fire one spec pass
    // (the decode that happens while the thumb travels to Right-⌘), append a
    // last 0.5s of silence (tap latency), then finish — the tail must come
    // from the cache with ZERO decode at stop.
    let src = cliArgs[2]
    guard let srcOff = findWavDataOffset(src), let sfh = FileHandle(forReadingAtPath: src) else {
        FileHandle.standardError.write("cannot read \(src)\n".data(using: .utf8)!); exit(1)
    }
    let total = (sfh.seekToEndOfFile() - srcOff) & ~1
    let sim = "/tmp/ptt_specsim.wav"
    FileManager.default.createFile(atPath: sim, contents: wavHeader(dataBytes: UInt32(total + 96000)))
    guard let out = FileHandle(forWritingAtPath: sim) else { exit(1) }
    out.seekToEndOfFile()
    let engine = ChunkEngine()
    engine.simStart(wav: sim, session: 0)
    let step = UInt64(max(20, cfg.chunkSeconds) * 32000) & ~1
    var done: UInt64 = 0
    while done < total {
        let take = min(step, total - done)
        sfh.seek(toFileOffset: srcOff + done)
        out.write(sfh.readData(ofLength: Int(take)))
        done += take
        if done < total { engine.simFire() }
    }
    out.write(Data(count: 80000))            // 2.5s pause before the "tap"
    let t0 = Date()
    engine.simSpec()                          // happens while he reaches for the key
    let specTime = -t0.timeIntervalSinceNow
    out.write(Data(count: 16000))             // 0.5s more silence: tap latency
    let sem = DispatchSemaphore(value: 0)
    var result: String?
    let t1 = Date()
    engine.finish { r in result = r; sem.signal() }
    sem.wait()
    let stopWait = -t1.timeIntervalSinceNow
    try? FileManager.default.removeItem(atPath: sim)
    guard let r = result else { print("SPEC-SIM: no cache — fell back"); exit(2) }
    print("SPEC-SIM: spec decode ran \(String(format: "%.1f", specTime))s BEFORE the tap; wait AFTER stop = \(String(format: "%.2f", stopWait))s")
    print(formatTranscript(r))
    exit(0)
}
if cliArgs.count >= 3, cliArgs[1] == "--caption-sim" {
    // Replay a WAV through the rolling-caption engine at the caption cadence
    // (audio-time, not wall-time) and print every HUD frame. Frames must only
    // ever grow at the tail — committed words never vanish or rewrite.
    let src = cliArgs[2]
    guard let srcOff = findWavDataOffset(src), let sfh = FileHandle(forReadingAtPath: src) else {
        FileHandle.standardError.write("cannot read \(src)\n".data(using: .utf8)!); exit(1)
    }
    let total = (sfh.seekToEndOfFile() - srcOff) & ~1
    let sim = "/tmp/ptt_captionsim.wav"
    FileManager.default.createFile(atPath: sim, contents: wavHeader(dataBytes: UInt32(total)))
    guard let out = FileHandle(forWritingAtPath: sim) else { exit(1) }
    out.seekToEndOfFile()
    let engine = CaptionEngine()
    guard engine.modelAvailable else { print("CAPTION-SIM: caption model missing"); exit(1) }
    var frame = 0
    engine.display = { t in frame += 1; print("[\(frame)] \(t)") }
    engine.simStart(wav: sim)
    let step = (UInt64(cfg.captionInterval * 32000)) & ~1
    var done: UInt64 = 0
    while done < total {
        let take = min(step, total - done)
        sfh.seek(toFileOffset: srcOff + done)
        out.write(sfh.readData(ofLength: Int(take)))
        done += take
        engine.simPass()
    }
    try? FileManager.default.removeItem(atPath: sim)
    exit(0)
}

// ===================== Main =====================
// NOTHING here may exit(1). launchd runs this with KeepAlive, so a fatal exit is
// not a clean failure, it is an invisible crash-loop: no menu bar icon, no window,
// no message, forever. Customer builds transcribe on the NessoTalk engine and
// deliberately ship with no local decode model at all, so a missing whisper-cli or
// a missing local model is the NORMAL state and must degrade, never terminate.
let localDecodeReady = FileManager.default.fileExists(atPath: WHISPER)
    && FileManager.default.fileExists(atPath: MODEL)
if !localDecodeReady {
    log("· local decode unavailable (whisper-cli: \(FileManager.default.fileExists(atPath: WHISPER) ? "found" : "missing"), model: \(FileManager.default.fileExists(atPath: MODEL) ? "found" : "missing")) — transcription runs on the NessoTalk engine")
}
if !FileManager.default.fileExists(atPath: WHISPER) {
    log("⚠️ whisper-cli not found in any Homebrew prefix — live captions and local fallback are off")
}
if !FileManager.default.fileExists(atPath: VAD_MODEL) {
    log("⚠️ VAD model missing at \(VAD_MODEL) — running without VAD (worse silence handling)")
}

// Sweep temp files orphaned by a crash/restart mid-recording — a 45-min
// orphan is ~86MB and sessionN restarts at 0, so stale high-N files linger.
if let tmpFiles = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") {
    for f in tmpFiles where f.hasPrefix("ptt_rec_") || f.hasPrefix("ptt_caption") || f.hasPrefix("ptt_chunk") {
        try? FileManager.default.removeItem(atPath: "/tmp/" + f)
    }
}

let dict = Dictation()
let ui = UIController()
// Live mic level -> HUD waveform (onLevel already hops to main inside ingest()).
dict.capturer.onLevel = { ui.setLevel($0) }

// v8.8 predictive preload: when the spec pass pre-decodes the tail during a
// pause, the full transcript already exists — start the active mode's rewrite
// right then, while the user is still deciding whether they're done. By the
// stop tap the rewrite is finished or nearly so. Resumed speech changes the
// transcript, which invalidates the pre-run automatically (the race is
// text-keyed), so a wrong guess costs one API call and never wrong output.
// Wired ONLY here in the daemon: the --chunk-sim/--spec-sim CLI paths build
// their own engines and must never spawn rewrite calls.
// v8.11: nothing to pre-run anymore — the mode transforms are local code and
// complete in microseconds, so "preload" is inherent in every delivery. The
// spec pass still pre-DECODES audio, which is the part worth pre-paying.

// ptt-dictate --hud-demo : show the recording HUD for ~9s with synthetic voice
// levels + a fake rolling transcript. No mic, no TCC — pure visual check of the
// pill (waveform animation + caption front-trim) without a live dictation.
if cliArgs.count >= 2, cliArgs[1] == "--settings-demo" {
    // Show the Settings window for a visual check (scrolling, layout). No mic,
    // no TCC. Screencapture it, then quit.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    SettingsWindow.shared.show()
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(0) }
    app.run()
}
if cliArgs.count >= 2, cliArgs[1] == "--hud-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    ui.setup()
    ui.recordingStarted()
    var t = 0.0
    let lvl = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
        t += 1.0 / 30
        let burst = max(0, sin(t * 1.1))               // talk / pause cycle
        let syll = 0.55 + 0.45 * sin(t * 9.0) * sin(t * 3.7)
        ui.setLevel(Float(burst > 0.15 ? syll : 0.02))
    }
    RunLoop.main.add(lvl, forMode: .common)
    let demoWords = ("okay so this is the new wispr style pill with the live waveform "
        + "and the transcript still rolls along the bottom exactly like before "
        + "committed words never vanish and the newest words are always visible").split(separator: " ")
    var shown = 0
    let cap = Timer(timeInterval: 0.22, repeats: true) { _ in
        guard shown < demoWords.count else { return }
        shown += 1
        ui.setCaption(demoWords[0..<shown].joined(separator: " "))
    }
    RunLoop.main.add(cap, forMode: .common)
    // Show the selected state of the mode button (as if Professional was picked).
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        ui.selectedMode = .professional
        ui.refreshModeButton()
    }
    // PTT_DEMO_SECS extends the demo window (the resize drag test needs ~20s).
    let demoSecs = Double(ProcessInfo.processInfo.environment["PTT_DEMO_SECS"] ?? "") ?? 9
    DispatchQueue.main.asyncAfter(deadline: .now() + demoSecs) { exit(0) }
    app.run()
}

// ptt-dictate --mode-info-demo : show the mode explainer card for ~6s. No mic,
// no TCC — a pure visual check that every mode block renders and wraps.
if cliArgs.count >= 2, cliArgs[1] == "--mode-info-demo" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    ModeInfoPanel.shared.show(onClose: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { exit(0) }
    app.run()
}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    log(granted
        ? "✓ Microphone granted"
        : "⚠️ Microphone NOT granted — System Settings ▸ Privacy & Security ▸ Microphone.")
}

ensureAccessibility()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon, but menu-bar item still shows
ui.setup()
if cfg.liveCaptions && !dict.captions.modelAvailable {
    log("⚠️ caption model missing at \(cfg.captionModel) — live captions disabled (download it or set CAPTION_MODEL in \(CONFIG_PATH))")
}

// No sleep/wake audio recovery is needed: AVCaptureSession capture is immune to the
// AVAudioEngine -10868 post-sleep wedge that used to kill dictation (see AudioCapturer).

// Global monitor: modifier changes (trigger up/down), regular keydowns, AND mouse
// activity — any of which while the trigger is held means it's a chord, not a tap.
// (Cmd-click, cmd-scroll, cmd-drag must never toggle the mic.)
func installMonitor() {
    NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown,
                                                 .leftMouseDown, .rightMouseDown,
                                                 .otherMouseDown, .scrollWheel]) { event in
        switch event.type {
        case .flagsChanged:
            if event.keyCode == cfg.hotkey {
                let down = (event.modifierFlags.rawValue & triggerKey(forCode: cfg.hotkey).bit) != 0
                if down { dict.triggerKeyDown(flags: event.modifierFlags) }
                else    { dict.triggerKeyUp() }
            } else {
                // some other modifier toggled while trigger may be held -> it's a chord
                dict.otherKeyActivity()
            }
        default:
            // Esc while recording = cancel (discard, nothing pasted).
            if event.type == .keyDown, event.keyCode == 53, dict.recording {
                dict.cancelRecording()
                return
            }
            // keyDown or any mouse event
            dict.otherKeyActivity()
        }
    }
    log("✓ key monitor armed — press Right ⌘ to toggle dictation")
}

// Without Accessibility trust, macOS delivers flagsChanged but WITHHOLDS keyDown
// from global monitors — the toggle would work while chord detection is silently
// dead, so every Right-⌘ shortcut would false-toggle the mic. Refuse to arm the
// trigger until trust is granted; poll so granting it Just Works without a restart.
var axWaitLogged = false
func armWhenTrusted() {
    if AXIsProcessTrusted() {
        installMonitor()
    } else {
        if !axWaitLogged {
            axWaitLogged = true
            log("⚠️ waiting for Accessibility — trigger key DISARMED until granted (System Settings ▸ Privacy & Security ▸ Accessibility ▸ ptt-dictate)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armWhenTrusted() }
    }
}
armWhenTrusted()

// ---- Test/automation hooks (so the toggle can be driven without a physical keypress) ----
// kill -USR1 <pid>  -> simulate one trigger TAP (toggle start/stop)
// kill -USR2 <pid>  -> paste a known test string into the focused field (tests the insert path)
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler { log("⌨︎ simulated tap (SIGUSR1)"); dict.toggle() }
usr1.resume()
let usr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
usr2.setEventHandler {
    log("⌨︎ simulated insert (SIGUSR2)")
    dict.insert("PTT_TEST_INSERT_OK")
}
usr2.resume()

let micPlan = resolveInputCandidates(cfg.inputDevice).map { $0.name }.joined(separator: " → ")
purgeLegacyPlaintext()
retentionSweep()
DispatchQueue.global().async { checkLicense() }
let licTimer = Timer(timeInterval: 12 * 3600, repeats: true) { _ in
    DispatchQueue.global().async { checkLicense() }
}
RunLoop.main.add(licTimer, forMode: .common)

log("▶ NessoTalk v8.24 (engine-only transcription · HUD always shows · 3-channel mic fix · smarter modes + keyword editor · decode race · cloud engine · self-tuning code modes · no-click = \(cfg.defaultMode)) up. license=\(cfg.licenseKey.isEmpty ? "dev(off)" : "on") · cloud=\(cfg.cloud && !cfg.licenseKey.isEmpty ? "on@engine(race)" : "off(local)") · Right ⌘ toggles · Option+Right ⌘ edits selection · menu-bar 🎙/🔴 shows state · spec=\(cfg.speculative ? "on" : "off") · polish=\(cfg.polish ? ("default-" + cfg.defaultMode + "@\(cfg.polishModel)[\(cfg.polishApps)]") : "off") · pro-apps=[\(cfg.proApps)] · lang=\(cfg.language) · learned=\(loadLearnedWords().count) · snippets=\(loadSnippets().count) · server=\(cfg.useServer ? "on@8977" : "off") · chunks=\(dict.chunks.enabled ? "on@\(Int(cfg.chunkSeconds))s" : "off") · live captions=\(cfg.liveCaptions && dict.captions.modelAvailable ? "on" : "off") · VAD=\(FileManager.default.fileExists(atPath: VAD_MODEL) ? "on@\(cfg.whisperMode ? min(cfg.vadThreshold, 0.15) : cfg.callMode ? min(cfg.vadThreshold, 0.2) : cfg.vadThreshold)" : "off") · preprocess=\(cfg.preprocess && FileManager.default.fileExists(atPath: FFMPEG) ? "on" : "off") · call-mode=\(cfg.callMode ? "ON" : "off") · whisper-mode=\(cfg.whisperMode ? "ON" : "off") · mic=\(cfg.inputDevice) [\(micPlan.isEmpty ? "system default" : micPlan)] · max \(Int(cfg.maxRecordSeconds))s")
app.run()
