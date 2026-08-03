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
let WHISPER = "/opt/homebrew/bin/whisper-cli"
let FFMPEG = "/opt/homebrew/bin/ffmpeg"
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
    // v8.2 lease: customer builds carry a LICENSE_KEY (from the nesso.tech
    // dashboard). The daemon checks in on launch + every 12h; revoked/expired
    // accounts disarm recording. Empty key = enforcement off (dev build).
    var licenseKey = ""
    var licenseUrl = "https://nesso.tech/api/license"
    // Server-side AI proxy: with a license key set, the rewrite modes run on
    // nesso.tech under our API key instead of needing the customer's own.
    // A cracked copy can't reach it without an active license.
    var polishProxyUrl = "https://nesso.tech/api/polish"

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
            # Decode language: en, es, ... or auto (captions stay English)
            LANGUAGE=en
            # Whisper mode: quiet-voice dictation (strong gain + low VAD gate). Toggle: ptt whisper
            WHISPER_MODE=0
            # Auto-Professional apps (bundle-id substrings). Empty disables.
            PRO_APPS=mobilesms,messages,mail,outlook,whatsapp,telegram,slack,discord
            # What a stop with NO chip clicked delivers: summarize | professional |
            # normal | ask (ask restores the old popup flow)
            DEFAULT_MODE=summarize
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
            case "DEFAULT_MODE":       if ["summarize", "professional", "normal", "raw", "ask"].contains(val.lowercased()) { c.defaultMode = val.lowercased() == "raw" ? "normal" : val.lowercased() }
            case "LICENSE_KEY":        c.licenseKey = val
            case "LICENSE_URL":        if !val.isEmpty { c.licenseUrl = val }
            case "POLISH_PROXY_URL":   if !val.isEmpty { c.polishProxyUrl = val }
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
let TRIGGER_KEYCODE: UInt16 = 54         // kVK_RightCommand
let TRIGGER_BIT: UInt = 0x10             // NX_DEVICERCMDKEYMASK (right-command down)
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
func effectivePrompt() -> String {
    let learned = loadLearnedWords()
    guard !learned.isEmpty else { return VOCAB_PROMPT }
    var prompt = VOCAB_PROMPT
    var budget = 200 - (prompt.split(separator: " ").count * 13 / 10)
    for w in learned {
        let cost = w.canonical.split(separator: " ").count * 13 / 10 + 1
        if budget - cost < 0 { break }
        prompt += " " + w.canonical + "."
        budget -= cost
    }
    return prompt
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
    let fd = open(LOG, O_WRONLY | O_APPEND | O_CREAT, 0o644)
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
        if let buf = pcmBuffer(from: sb) { ingest(buf) }
    }

    private func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                              into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
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
enum DeliverMode { case ask, summarize, raw, professional }

// ===================== UI: menu bar + live-caption HUD =====================
final class UIController: NSObject {
    var statusItem: NSStatusItem?
    var panel: NSPanel?
    var captionField: NSTextField?
    var elapsedField: NSTextField?
    var waveform: WaveformView?
    var modeButtons: [DeliverMode: NSButton] = [:]
    var selectedMode: DeliverMode = .ask     // main-thread only; captured at stop
    var uiTimer: Timer?
    var recordStart: Date?
    var busyCount = 0
    var toggleMenuItem: NSMenuItem?

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
        let w: CGFloat = 620, h: CGFloat = 128
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
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.92).cgColor
        root.layer?.cornerRadius = 24
        root.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor
        root.layer?.borderWidth = 1

        let elapsed = NSTextField(labelWithString: "0:00")
        elapsed.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        elapsed.textColor = NSColor(calibratedWhite: 0.85, alpha: 1)
        elapsed.frame = NSRect(x: 20, y: h - 33, width: 90, height: 18)
        root.addSubview(elapsed)
        elapsedField = elapsed

        // The waveform IS the recording indicator (replaces the old red dot).
        let wfW: CGFloat = 220, wfH: CGFloat = 30
        let wf = WaveformView(frame: NSRect(x: (w - wfW) / 2, y: h - 40, width: wfW, height: wfH))
        root.addSubview(wf)
        waveform = wf

        let hint = NSTextField(labelWithString: "Right ⌘ stops · Esc cancels")
        hint.font = .systemFont(ofSize: 12, weight: .regular)
        hint.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        hint.alignment = .right
        hint.frame = NSRect(x: w - 160, y: h - 32, width: 142, height: 16)
        root.addSubview(hint)

        let caption = NSTextField(labelWithString: "Listening…")
        caption.font = .systemFont(ofSize: 16, weight: .medium)
        caption.textColor = .white
        caption.frame = NSRect(x: 18, y: 42, width: w - 36, height: 48)
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        root.addSubview(caption)
        captionField = caption

        // Mode row: pick THIS dictation's delivery while still talking — no
        // popup afterwards. Click the active one again to unselect (back to the
        // normal ask flow). Resets to ask on every new recording.
        let sumBtn = makeModeButton("Summarize", x: 140, width: 110, action: #selector(modeSummarize))
        let rawBtn = makeModeButton("Normal", x: 260, width: 90, action: #selector(modeRaw))
        let proBtn = makeModeButton("Professional", x: 360, width: 120, action: #selector(modePro))
        root.addSubview(sumBtn); root.addSubview(rawBtn); root.addSubview(proBtn)
        modeButtons = [.summarize: sumBtn, .raw: rawBtn, .professional: proBtn]
        restyleModeButtons()

        p.contentView = root
        panel = p

        // One persistent ticker drives the elapsed readout, the pulsing dot,
        // and the menu-bar timer. Cheap, and far fewer states than start/stop timers.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // .common: keeps ticking while the status menu is open
        uiTimer = t
    }

    func tick() {
        guard let start = recordStart else { return }
        let s = Int(Date().timeIntervalSince(start))
        let t = String(format: "%d:%02d", s / 60, s % 60)
        elapsedField?.stringValue = t
        statusItem?.button?.title = "🔴 \(t)"
    }

    func recordingStarted() {
        recordStart = Date()
        statusItem?.button?.title = "🔴 0:00"
        toggleMenuItem?.title = "Stop & Transcribe (Right ⌘)"
        guard cfg.liveCaptions, dict.captions.modelAvailable else { return }
        captionField?.stringValue = "Listening…"
        elapsedField?.stringValue = "0:00"
        selectedMode = .ask
        restyleModeButtons()
        // HUD goes on the screen the user is actually on (the one under the
        // mouse) — NSScreen.main is just the primary display for an accessory app.
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let p = panel, let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - p.frame.width / 2, y: f.minY + 28,
                              width: p.frame.width, height: p.frame.height), display: true)
            p.orderFrontRegardless()
            waveform?.start()
        }
    }

    func recordingStopped() {
        recordStart = nil
        waveform?.stop()
        panel?.orderOut(nil)
        toggleMenuItem?.title = "Start Dictation (Right ⌘)"
        refreshIdleOrBusy()
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

    private func makeModeButton(_ title: String, x: CGFloat, width: CGFloat, action: Selector) -> NSButton {
        let b = ClickThroughButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 13
        b.frame = NSRect(x: x, y: 8, width: width, height: 26)
        return b
    }

    private func restyleModeButtons() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        for (mode, b) in modeButtons {
            let sel = mode == selectedMode
            b.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: sel ? 0.30 : 0.10).cgColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: sel ? .bold : .medium),
                .foregroundColor: sel ? NSColor.white : NSColor(calibratedWhite: 0.75, alpha: 1),
                .paragraphStyle: center,
            ])
        }
    }

    @objc func modeSummarize() { setMode(.summarize) }
    @objc func modeRaw()       { setMode(.raw) }
    @objc func modePro()       { setMode(.professional) }
    private func setMode(_ m: DeliverMode) {
        selectedMode = selectedMode == m ? .ask : m
        restyleModeButtons()
        log("· HUD mode: \(selectedMode)")
    }

    func setCaption(_ text: String) {
        guard let field = captionField else { return }
        // Trim from the FRONT until the tail fits two lines — the newest words
        // must never be the ones clipped. (cellSize on the field's own cell
        // honors maximumNumberOfLines, so measure with an uncapped cell.)
        var tail = String(text.suffix(150))
        let measure = NSTextFieldCell(textCell: tail)
        measure.font = field.font
        measure.wraps = true
        let bounds = NSRect(x: 0, y: 0, width: field.frame.width, height: .greatestFiniteMagnitude)
        while measure.cellSize(forBounds: bounds).height > 40, let sp = tail.firstIndex(of: " ") {
            tail = String(tail[tail.index(after: sp)...])
            measure.stringValue = tail
        }
        field.stringValue = tail
    }

    @objc func menuToggle() { dict.toggle() }
    @objc func menuCancel() { dict.cancelRecording() }
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
    let chain = cfg.whisperMode
        ? "highpass=f=80,afftdn=nf=-18:tn=1,speechnorm=e=25:r=0.0002:l=1"
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
    c.isEmpty ? "" : "\nContext: the user is dictating into \(c). Write what fits that destination; never mention this context."
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
// The last valid token is cached and honors its own 14-day expiry offline.
// Invalid/revoked/expired/seat-capped -> recording disarms (an in-flight
// session still finishes; we never eat words mid-recording). Empty key = dev.
let LICENSE_PUBKEY_B64 = "DgOqB8kIOGQDePmlGSFcbZVVbujNZ9CVM+XkPFSJZjw="
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
                   "-d", "{\"key\":\"\(cfg.licenseKey)\",\"machine\":\"\(machineID())\"}"]
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

func commandEdit(selection: String, instruction: String) -> String? {
    let payload = "SELECTED TEXT:\n\(selection)\n\nINSTRUCTION:\n\(instruction)"
    let timeout = max(30.0, Double(selection.count) / 40.0)
    var out: String?
    out = polishViaProxy(payload, timeout: timeout, mode: "command")
    if out == nil, cfg.polishKey.hasPrefix("gsk_") { out = polishViaGroq(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
    else if out == nil, !cfg.polishKey.isEmpty { out = polishViaAPI(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
    if out == nil { out = polishViaClaudeCLI(payload, timeout: timeout, instruction: COMMAND_INSTRUCTION) }
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
        let raw = transcribe(base + ".wav", base)
        try? FileManager.default.removeItem(atPath: base + ".wav")
        try? FileManager.default.removeItem(atPath: base + ".txt")
        guard let text = raw else { return }
        specText = text; specFrom = lastCutByte; specTo = usable
        log("· tail pre-decoded during pause · \(Int(pending / 32000))s → \(String(format: "%.1f", -t0.timeIntervalSinceNow))s")
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
        let raw = transcribe(base + ".wav", base)
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
    var savedOriginal: String?
    var lastInsertChangeCount = -1

    // Solo-press tracking for the trigger key.
    var triggerDown = false
    var soloCandidate = false       // true while the current press has seen no other key
    var cmdCandidate = false        // Option was held at press time -> command mode tap
    var commandSelection: String?   // non-nil while a command-mode recording is in flight

    // ---- Trigger key state machine (driven by the global event monitor) ----

    func triggerKeyDown(flags: NSEvent.ModifierFlags) {
        triggerDown = true
        // Not a solo press if any other modifier is already held (aborted chords,
        // both Cmd keys, remapper-latched modifiers). Option alone is special:
        // Option-held + Right-⌘ tap = command mode (edit the selection by voice).
        let option = flags.contains(.option)
        let othersHeld = flags.contains(.shift) || flags.contains(.control)
            || (flags.rawValue & LEFT_CMD_BIT) != 0
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
        let saved = pb.string(forType: .string)
        postCmdKey(8)   // kVK_ANSI_C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, !self.recording else { return }
            guard pb.changeCount != before, let sel = pb.string(forType: .string),
                  !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("✕ command mode: no text selected — highlight text, then Option+Right ⌘")
                playSound("Basso")
                return
            }
            if let s = saved { pb.clearContents(); pb.setString(s, forType: .string) }
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

    func cancelRecording() {
        guard recording else { return }
        recording = false
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
        // Screen context for the polish rewrites — captured NOW, same reason.
        let ctx = frontContext()
        // Mode clicked on the recording HUD (main thread, and so are we) —
        // captured NOW so a click during a long transcription can't retarget it.
        let hudMode = ui.selectedMode
        // Command mode: consume the pending selection; this transcript is an
        // edit instruction, not a dictation.
        let cmdSelection = commandSelection
        commandSelection = nil
        // Paste + log + cleanup on main — the single exit for every path below.
        let finish: (String, String) -> Void = { [weak self] text, tag in
            DispatchQueue.main.async {
                if !text.isEmpty {
                    self?.insert(text)
                    log("✓\(tag) \(text)")
                    playSound("Glass")
                } else {
                    log("… empty transcription (session \(n))")
                    playSound("Basso")
                }
                ui.setBusy(-1)
                // Keep the most recent clip for forensics — jobs complete out of
                // session order, so only a NEWER session may take the slot.
                if let self = self, n > self.lastSavedN {
                    try? FileManager.default.removeItem(atPath: "/tmp/ptt_last.wav")
                    try? FileManager.default.moveItem(atPath: wav, toPath: "/tmp/ptt_last.wav")
                    self.lastSavedN = n
                } else {
                    try? FileManager.default.removeItem(atPath: wav)
                }
                try? FileManager.default.removeItem(atPath: "/tmp/ptt_rec_\(n).txt")
            }
        }
        // The AI rewrite, off-main (blocks on the API call); raw pastes on failure.
        let summarize: (String) -> Void = { text in
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                if let polished = polishForAI(text, context: ctx) {
                    log("· raw: \(text)")
                    finish(polished, " ⚡\(String(format: "%.1f", -t0.timeIntervalSinceNow))s polish")
                } else {
                    log("⚠️ polish unavailable — pasting raw transcript")
                    finish(text, "")
                }
            }
        }
        // The professional rewrite (texting/email prose), same shape as summarize.
        let professional: (String) -> Void = { text in
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                if let polished = polishForText(text, context: ctx) {
                    log("· raw: \(text)")
                    finish(polished, " ⚡\(String(format: "%.1f", -t0.timeIntervalSinceNow))s pro")
                } else {
                    log("⚠️ professional polish unavailable — pasting raw transcript")
                    finish(text, "")
                }
            }
        }
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
                        log("· cmd instruction: \(text)")
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
            switch hudMode {
            case .raw:          finish(text, ""); return
            case .summarize:    summarize(text); return
            case .professional: professional(text); return
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
            default:   // "ask" — the pre-v8.3 popup/auto flow, AI apps only
                guard aiTarget else { finish(text, ""); return }
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
    func insert(_ text: String) {
        let pb = NSPasteboard.general
        // Only capture the "original" if the pasteboard isn't still holding OUR
        // previous transcript — otherwise overlapping inserts would "restore"
        // transcript A over the user's real clipboard content.
        if pb.changeCount != lastInsertChangeCount {
            savedOriginal = pb.string(forType: .string)
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
            pb.clearContents()
            if let old = self?.savedOriginal { pb.setString(old, forType: .string) }
        }
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
guard FileManager.default.fileExists(atPath: WHISPER) else {
    log("!! whisper-cli missing at \(WHISPER)"); exit(1)
}
guard FileManager.default.fileExists(atPath: MODEL) else {
    log("!! model missing at \(MODEL)"); exit(1)
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

// ptt-dictate --hud-demo : show the recording HUD for ~9s with synthetic voice
// levels + a fake rolling transcript. No mic, no TCC — pure visual check of the
// pill (waveform animation + caption front-trim) without a live dictation.
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
    // Show the selected state of the mode row (as if Professional was clicked).
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ui.modePro() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
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
            if event.keyCode == TRIGGER_KEYCODE {
                let down = (event.modifierFlags.rawValue & TRIGGER_BIT) != 0
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
DispatchQueue.global().async { checkLicense() }
let licTimer = Timer(timeInterval: 12 * 3600, repeats: true) { _ in
    DispatchQueue.global().async { checkLicense() }
}
RunLoop.main.add(licTimer, forMode: .common)

log("▶ NessoTalk v8.4 (signed lease + server AI proxy · no-click = \(cfg.defaultMode)) up. license=\(cfg.licenseKey.isEmpty ? "dev(off)" : "on") · Right ⌘ toggles · Option+Right ⌘ edits selection · menu-bar 🎙/🔴 shows state · spec=\(cfg.speculative ? "on" : "off") · polish=\(cfg.polish ? ("default-" + cfg.defaultMode + "@\(cfg.polishModel)[\(cfg.polishApps)]") : "off") · pro-apps=[\(cfg.proApps)] · lang=\(cfg.language) · learned=\(loadLearnedWords().count) · snippets=\(loadSnippets().count) · server=\(cfg.useServer ? "on@8977" : "off") · chunks=\(dict.chunks.enabled ? "on@\(Int(cfg.chunkSeconds))s" : "off") · live captions=\(cfg.liveCaptions && dict.captions.modelAvailable ? "on" : "off") · VAD=\(FileManager.default.fileExists(atPath: VAD_MODEL) ? "on@\(cfg.whisperMode ? min(cfg.vadThreshold, 0.15) : cfg.callMode ? min(cfg.vadThreshold, 0.2) : cfg.vadThreshold)" : "off") · preprocess=\(cfg.preprocess && FileManager.default.fileExists(atPath: FFMPEG) ? "on" : "off") · call-mode=\(cfg.callMode ? "ON" : "off") · whisper-mode=\(cfg.whisperMode ? "ON" : "off") · mic=\(cfg.inputDevice) [\(micPlan.isEmpty ? "system default" : micPlan)] · max \(Int(cfg.maxRecordSeconds))s")
app.run()
