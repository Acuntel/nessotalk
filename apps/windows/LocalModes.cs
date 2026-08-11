using System.Text;
using System.Text.RegularExpressions;

namespace PttDictate;

/// <summary>
/// Deterministic, code-only versions of the rewrite modes (v8.10, same logic as
/// the Mac build's localModeTransform in ptt-dictate.swift). They are the floor,
/// not the ceiling: the AI proxy is tried first, and only when it cannot answer
/// does the picked mode fall back to these instead of silently pasting the raw
/// transcript. No network, no key, pure text transforms.
/// </summary>
internal static class LocalModes
{
    public static string Transform(string text, string mode)
    {
        var cleaned = Professional(text);
        var candidate = mode switch
        {
            "summarize" => Summarize(text),
            "professional" => cleaned,
            "agent" => AgentBrief(text),
            "expand" => Expand(text),
            _ => text,
        };
        if (mode == "professional" || candidate == text) return candidate;
        return FactGuardrail(cleaned, candidate);
    }

    // Fact guardrail: a transform may reorganize, never lose. Every number that
    // survives cleanup must appear in the output, or the safer cleaned text
    // ships instead. A guarantee code can make that a model cannot.
    private static readonly Regex NumberToken = new(@"\d[\d,.]*\d|\d", RegexOptions.Compiled);

    private static string FactGuardrail(string cleaned, string candidate)
    {
        var pool = NumberToken.Matches(candidate).Select(m => m.Value).ToList();
        foreach (Match m in NumberToken.Matches(cleaned))
        {
            var i = pool.IndexOf(m.Value);
            if (i < 0) return cleaned;
            pool.RemoveAt(i);
        }
        return candidate;
    }

    // ── shared cleanup ──────────────────────────────────────────────────────

    private static readonly Regex CorrectionMarker = new(
        @"\b(?:no,?\s+wait|wait,?\s+no|scratch that|actually,?\s+no|no,?\s+actually|i mean,)\b[,.]?\s*",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex LeadFiller = new(
        @"^(?:ok(?:ay)?|so|yeah|alright|well|anyway|um|uh)[,]?\s+",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly (Regex, string)[] FillerRules =
    {
        (new Regex(@",\s*(?:like|you know|i mean|i guess)\s*,", RegexOptions.Compiled | RegexOptions.IgnoreCase), ","),
        (new Regex(@"\b(?:you know|i guess|basically|literally)\s*,\s*", RegexOptions.Compiled | RegexOptions.IgnoreCase), ""),
        // v8.21: trailing throwaways and function-word stutter doubles.
        // Hedges (kind of / sort of / right?) carry meaning and stay.
        (new Regex(@",?\s*(?:you know what i mean|if that makes sense|or whatever|and stuff(?: like that)?|and everything)\s*([,.?!]|$)", RegexOptions.Compiled | RegexOptions.IgnoreCase), "$1"),
        (new Regex(@"\b(the|a|an|to|of|in|on|at|and|but|or|we|i|it|is|was|for|with)\s+\1\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "$1"),
        (new Regex(@"\s{2,}", RegexOptions.Compiled), " "),
    };

    // Only the unambiguous set: "ill", "id", "its" have real non-contraction readings.
    private static readonly (Regex, string)[] Contractions =
    {
        (new Regex(@"\bdont\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "don't"),
        (new Regex(@"\bcant\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "can't"),
        (new Regex(@"\bwont\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "won't"),
        (new Regex(@"\bdidnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "didn't"),
        (new Regex(@"\bdoesnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "doesn't"),
        (new Regex(@"\bisnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "isn't"),
        (new Regex(@"\bwasnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "wasn't"),
        (new Regex(@"\bcouldnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "couldn't"),
        (new Regex(@"\bshouldnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "shouldn't"),
        (new Regex(@"\bwouldnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "wouldn't"),
        (new Regex(@"\bhasnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "hasn't"),
        (new Regex(@"\bhavent\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "haven't"),
        (new Regex(@"\bthats\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "that's"),
        (new Regex(@"\bwhats\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "what's"),
        (new Regex(@"\bheres\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "here's"),
        (new Regex(@"\btheres\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "there's"),
        (new Regex(@"\byoure\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "you're"),
        (new Regex(@"\btheyre\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "they're"),
        // v8.21: the rest of the unambiguous set (each is a non-word without
        // its apostrophe; "lets", "were", "its", "ill", "id" stay out).
        (new Regex(@"\barent\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "aren't"),
        (new Regex(@"\bwerent\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "weren't"),
        (new Regex(@"\bhadnt\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "hadn't"),
        (new Regex(@"\byoull\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "you'll"),
        (new Regex(@"\btheyll\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "they'll"),
        (new Regex(@"\btheyve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "they've"),
        (new Regex(@"\bweve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "we've"),
        (new Regex(@"\byouve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "you've"),
        (new Regex(@"\btheyd\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "they'd"),
        (new Regex(@"\bwhos\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "who's"),
        (new Regex(@"\bhows\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "how's"),
        (new Regex(@"\bwheres\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "where's"),
        (new Regex(@"\bcouldve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "could've"),
        (new Regex(@"\bshouldve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "should've"),
        (new Regex(@"\bwouldve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "would've"),
        (new Regex(@"\bitll\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "it'll"),
        (new Regex(@"\bthatll\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "that'll"),
        (new Regex(@"\bmustve\b", RegexOptions.Compiled | RegexOptions.IgnoreCase), "must've"),
        (new Regex(@"\bim\b", RegexOptions.Compiled), "I'm"),
        (new Regex(@"\bive\b", RegexOptions.Compiled), "I've"),
        (new Regex(@"\bi\b", RegexOptions.Compiled), "I"),
    };

    /// Sentence end only at ".?!" followed by whitespace and an uppercase or
    /// digit start, or end of text: "theme.ts" and "3.5" stay whole.
    private static List<string> SplitSentences(string text)
    {
        var output = new List<string>();
        var current = new StringBuilder();
        for (var i = 0; i < text.Length; i++)
        {
            current.Append(text[i]);
            if (text[i] is '.' or '?' or '!')
            {
                var j = i + 1;
                while (j < text.Length && text[j] == ' ') j++;
                var atEnd = j >= text.Length;
                if (atEnd || (j > i + 1 && (char.IsUpper(text[j]) || char.IsDigit(text[j]))))
                {
                    var t = current.ToString().Trim();
                    if (t.Length > 0) output.Add(t);
                    current.Clear();
                }
            }
        }
        var tail = current.ToString().Trim();
        if (tail.Length > 0) output.Add(tail);
        return output;
    }

    /// "start tuesday no wait wednesday" -> "start wednesday". A short correction
    /// replaces the same number of trailing words; a long one replaces the clause
    /// back to the previous comma.
    private static string ResolveSelfCorrections(string sentence)
    {
        var s = sentence;
        for (var m = CorrectionMarker.Match(s); m.Success; m = CorrectionMarker.Match(s))
        {
            var before = s[..m.Index];
            var after = s[(m.Index + m.Length)..];
            var afterWords = after.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (afterWords.Length is > 0 and <= 3)
            {
                var beforeWords = before.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
                beforeWords.RemoveRange(Math.Max(0, beforeWords.Count - afterWords.Length),
                                        Math.Min(afterWords.Length, beforeWords.Count));
                beforeWords.Add(after);
                s = string.Join(' ', beforeWords);
            }
            else
            {
                var comma = before.LastIndexOf(',');
                s = comma >= 0 ? before[..comma] + ", " + after : after;
            }
        }
        return s;
    }

    private static string StripSpokenFiller(string sentence)
    {
        var s = sentence;
        // Throat-clearing stacks ("okay so um…"), so the lead rule loops.
        for (var m = LeadFiller.Match(s); m.Success; m = LeadFiller.Match(s))
            s = s[m.Length..];
        foreach (var (rx, replacement) in FillerRules) s = rx.Replace(s, replacement);
        return s.Trim();
    }

    private static string FixContractions(string s)
    {
        foreach (var (rx, replacement) in Contractions) s = rx.Replace(s, replacement);
        return s;
    }

    private static string SentenceCased(string s)
    {
        var t = s.Trim();
        if (t.Length == 0) return t;
        t = char.ToUpper(t[0]) + t[1..];
        if (!".?!:".Contains(t[^1])) t += ".";
        return t;
    }

    // Days and months are always capitalized in written English, and whisper
    // writes them lowercase mid-sentence. Orthography, not rewording, so it is
    // safe in every mode including Professional. "May" and "March" are
    // deliberately absent: ordinary words far more often than months in
    // speech, and a wrong capital is worse than a missing one.
    private static readonly Regex[] CalendarWords =
    {
        new(@"\bmonday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\btuesday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bwednesday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bthursday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bfriday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bsaturday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bsunday\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bjanuary\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bfebruary\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bapril\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bjune\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bjuly\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\baugust\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bseptember\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\boctober\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bnovember\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
        new(@"\bdecember\b", RegexOptions.Compiled | RegexOptions.IgnoreCase),
    };

    private static string CapitalizeCalendar(string s)
    {
        foreach (var rx in CalendarWords)
            s = rx.Replace(s, m => char.ToUpper(m.Value[0]) + m.Value[1..].ToLowerInvariant());
        return s;
    }

    private static List<string> CleanedSentences(string text) =>
        SplitSentences(text)
            .Select(s => CapitalizeCalendar(FormatSpokenUnits(FixContractions(StripSpokenFiller(ResolveSelfCorrections(s))))))
            .Where(s => s.Length > 0)
            .ToList();

    /// Spoken task descriptions are comma-glued run-ons, so the agent brief
    /// sorts CLAUSES, not sentences. Tiny fragments merge back into a neighbor.
    private static List<string> TaskClauses(string text)
    {
        var lead = new Regex(@"^(?:and|but|then|also)\s+", RegexOptions.IgnoreCase);
        var clauses = new List<string>();
        foreach (var sentence in CleanedSentences(text))
        {
            foreach (var piece in sentence.Split(", "))
            {
                var c = lead.Replace(piece.Trim(), "");
                if (c.Length == 0) continue;
                if (c.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length < 3 && clauses.Count > 0)
                    clauses[^1] += ", " + c;
                else
                    clauses.Add(c);
            }
        }
        return clauses;
    }

    // ── the four modes ──────────────────────────────────────────────────────

    /// Whisper glues spoken clauses into comma run-ons. For prose, split at
    /// ", and / , but / , so " when BOTH sides are substantial (4+ words).
    private static IEnumerable<string> SplitRunOns(string sentence)
    {
        var parts = new List<string> { sentence };
        foreach (var joiner in new[] { ", and ", ", but ", ", so " })
        {
            var next = new List<string>();
            foreach (var part in parts)
            {
                var rest = part;
                int idx;
                while ((idx = rest.IndexOf(joiner, StringComparison.Ordinal)) >= 0)
                {
                    var head = rest[..idx];
                    var tail = rest[(idx + joiner.Length)..];
                    if (head.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length < 4 ||
                        tail.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length < 4) break;
                    next.Add(head);
                    rest = tail;
                }
                next.Add(rest);
            }
            parts = next;
        }
        return parts;
    }

    /// "4500 dollars" -> "$4,500" — ONLY when the word "dollars" anchors it, so
    /// invoice numbers, years, and IDs are never touched.
    private static readonly Regex SpokenMoney = new(@"\b(\d{1,9}) dollars\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static string FormatSpokenMoney(string s) =>
        SpokenMoney.Replace(s, m => long.TryParse(m.Groups[1].Value, out var n)
            ? "$" + n.ToString("N0", System.Globalization.CultureInfo.InvariantCulture)
            : m.Value);

    // "35 percent" -> "35%", "9 am" -> "9 AM". Digit-anchored so "I am" and
    // numberless uses of "percent" are never touched (v8.16 parity).
    private static readonly Regex SpokenPercent = new(@"\b(\d+(?:\.\d+)?) percent\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex SpokenAmPm = new(@"\b(\d{1,2}(?::\d{2})?)\s?(am|pm)\b",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static string FormatSpokenUnits(string s)
    {
        var t = FormatSpokenMoney(s);
        t = SpokenPercent.Replace(t, "$1%");
        t = SpokenAmPm.Replace(t, m => m.Groups[1].Value + " " + m.Groups[2].Value.ToUpperInvariant());
        return t;
    }

    /// Professional: the speaker's own words, minus the junk, cased and punctuated.
    /// Unit formatting already happened in CleanedSentences, shared by every mode.
    // v8.21 (email-convention research, Mac parity): greeting and sign-off
    // get their own lines, unambiguous questions get their question marks
    // back, and long dictations break into 2-3 sentence paragraphs.
    private static readonly Regex QuestionStart = new(
        @"^(?:(?:can|could|would|will|should|shall|do|does|did|is|are|was|were|am|have|has|won'?t|don'?t|didn'?t|isn'?t|aren'?t|shouldn'?t|couldn'?t|wouldn'?t) (?:you|we|i|it|they|he|she|that|this|there|anyone|the)\b|(?:what|when|where|why|how|who|which) (?:can|could|would|will|should|shall|do|does|did|is|are|was|were|am|have|has)\b|(?:what|when|where|why|how|who|which) (?:about|much|many|long|often|soon)\b)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex GreetingShape = new(
        @"^(?:hey|hi|hello|good morning|good afternoon|good evening|dear) [a-z]+(?: [a-z]+)?$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex SignoffShape = new(
        @"^(?:thanks|thank you|thanks so much|thanks a lot|cheers|best|talk soon|see you (?:then|soon|tomorrow)|appreciate it)[.,!]?$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static string InferQuestion(string s) =>
        s.EndsWith('.') && QuestionStart.IsMatch(s) ? s[..^1] + "?" : s;

    private static string Professional(string text)
    {
        var sentences = CleanedSentences(text)
            .SelectMany(SplitRunOns)
            .Select(SentenceCased)
            .Select(InferQuestion)
            .ToList();

        string? greeting = null;
        if (sentences.Count > 0)
        {
            var bare = sentences[0].EndsWith('.') ? sentences[0][..^1] : sentences[0];
            if (bare.Split(' ').Length <= 4 && GreetingShape.IsMatch(bare))
            {
                var words = bare.Split(' ');
                words[^1] = char.ToUpper(words[^1][0]) + words[^1][1..];
                greeting = string.Join(' ', words) + ",";
                sentences.RemoveAt(0);
            }
        }
        string? signoff = null;
        if (sentences.Count > 0 && sentences[^1].Split(' ').Length <= 4 && SignoffShape.IsMatch(sentences[^1]))
        {
            signoff = sentences[^1];
            sentences.RemoveAt(sentences.Count - 1);
        }

        var paras = new List<string>();
        if (sentences.Count <= 3)
        {
            if (sentences.Count > 0) paras.Add(string.Join(' ', sentences));
        }
        else
        {
            for (var i = 0; i < sentences.Count; i += 3)
                paras.Add(string.Join(' ', sentences.Skip(i).Take(3)));
        }

        var output = new List<string>();
        if (greeting != null) output.Add(greeting);
        output.AddRange(paras);
        if (signoff != null) output.Add(signoff);
        return string.Join("\n\n", output);
    }

    /// Summarize: structure without condensing. Enumeration leads become a
    /// dashed list, topic shifts start a new paragraph. Nothing is dropped.
    private static string Summarize(string text)
    {
        var listLead = new Regex(
            @"^(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|then|next|also|finally|lastly|on top of that|(?:number|point|step) \w+)[,]?\s+",
            RegexOptions.IgnoreCase);
        var topicShift = new Regex(
            @"^(?:anyway|separately|one more thing|oh and|on another note|switching gears|next thing|the other thing|last thing|by the way|real quick|also wanted to)[,]?\s+",
            RegexOptions.IgnoreCase);
        // Short, self-contained commitments collect into an Action items block
        // at the end (v8.16). Long sentences with an action cue stay in place.
        var actionCue = new Regex(@"\b(?:need(?:s)? to|have to|remember to|don'?t forget|make sure to|todo|to-do)\b",
            RegexOptions.IgnoreCase);
        // v8.21: decisions get the same treatment as actions.
        var decisionCue = new Regex(@"\b(?:we decided|i decided|we agreed|let'?s go with|the plan is|we'?re going with|the decision is|going to go with)\b",
            RegexOptions.IgnoreCase);
        var blocks = new List<string>();
        var para = new List<string>();
        var list = new List<string>();
        var actions = new List<string>();
        var decisions = new List<string>();
        void FlushPara() { if (para.Count > 0) { blocks.Add(string.Join(' ', para)); para.Clear(); } }
        void FlushList() { if (list.Count > 0) { blocks.Add(string.Join('\n', list.Select(x => "- " + x))); list.Clear(); } }
        var sentences = CleanedSentences(text).SelectMany(SplitRunOns).ToList();
        foreach (var s in sentences)
        {
            if (sentences.Count > 2 &&
                s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 20 &&
                decisionCue.IsMatch(s))
            {
                decisions.Add(SentenceCased(s));
                continue;
            }
            if (sentences.Count > 2 &&
                s.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 20 &&
                actionCue.IsMatch(s))
            {
                actions.Add(SentenceCased(s));
                continue;
            }
            var listMatch = listLead.Match(s);
            var shiftMatch = topicShift.Match(s);
            if (listMatch.Success)
            {
                FlushPara();
                list.Add(SentenceCased(s[listMatch.Length..]));
            }
            else if (shiftMatch.Success)
            {
                FlushList(); FlushPara();
                para.Add(SentenceCased(s[shiftMatch.Length..]));
            }
            else
            {
                FlushList();
                para.Add(SentenceCased(s));
                if (para.Count >= 3) FlushPara();
            }
        }
        FlushList(); FlushPara();
        if (decisions.Count > 0)
            blocks.Add("Decisions\n" + string.Join('\n', decisions.Select(x => "- " + x)));
        if (actions.Count > 0)
            blocks.Add("Action items\n" + string.Join('\n', actions.Select(x => "- " + x)));
        return string.Join("\n\n", blocks);
    }

    /// Agent v2 (matches the Mac build): weighted cue scoring per clause, tried
    /// at two strictness levels, and the better-shaped brief wins. An ambiguous
    /// clause stays in Goal on purpose — precision beats recall. Extra cues
    /// hot-load from mode-rules in the app data dir ("constraint: hands off = 3").
    private static List<(string Section, string Pattern, double Weight)> CueTable()
    {
        var cues = new List<(string, string, double)>
        {
            ("constraint", @"\b(?:don'?t|do not|shouldn'?t|should not|must not|never|avoid|without (?:breaking|touching)|only touch|hands off)\b", 3),
            ("constraint", @"\b(?:make sure|keep (?:the|it|everything)|leave (?:the|it)|stay (?:away from|out of)|be careful)\b", 2),
            ("done", @"\b(?:done when|it works when|tests? (?:pass|passing)|verify that|acceptance criteria)\b", 3),
            ("done", @"\b(?:should (?:return|show|display|pass|see|survive)|expect(?:ed)? to|so that|when (?:i|you|it)'?m?s? (?:done|finished))\b", 2),
            ("context", @"\b(?:error|stack trace|crash(?:es|ing)?|the bug|fails?|failing|broken)\b", 3),
            ("context", @"(?:\b(?:currently|right now|at the moment|today it)\b|[\w-]+\.(?:swift|ts|tsx|js|jsx|py|go|cs|rb|css|html|json|md)\b|/[\w./-]{3,})", 2),
            ("goal", @"^(?:please\s+)?(?:add|fix|build|make|create|update|change|remove|delete|implement|wire|write|move|rename|refactor|redesign|set up|hook up|clean up|deploy|ship|migrate|port|convert|integrate|optimize|speed up|install|configure|test|style|animate|publish|upgrade|swap|replace|extract|split|merge|connect|automate)\b", 3),
            ("goal", @"\b(?:i (?:want|need) (?:you )?to|can you|we need to|the goal is|i'?m trying to)\b", 3),
            ("goal", @"\b(?:it should|it needs to|there should be)\b", 1.5),
            // v8.21 additions (Mac parity): deadlines/budgets are constraints,
            // attempts and current state are context, outcome shapes are done.
            ("constraint", @"\b(?:has to stay|keep it under|no more than|at most|can'?t|cannot|instead of|rather than|without asking|asap|by (?:tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|the demo|end of (?:day|week))|deadline)\b", 2),
            ("done", @"\b(?:end result|final result|should end up|once it'?s|success (?:is|means)|i can tell it worked|at the end|the output should)\b", 2),
            ("context", @"\b(?:i tried|we tried|last time|yesterday|the problem is|what'?s happening is|the repo|the branch|the pr|right now it)\b", 2),
        };
        try
        {
            var path = Path.Combine(AppPaths.Create().Root, "mode-rules");
            if (File.Exists(path))
            {
                foreach (var raw in File.ReadAllLines(path))
                {
                    var line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith('#')) continue;
                    var colon = line.IndexOf(':');
                    if (colon <= 0) continue;
                    var section = line[..colon].Trim().ToLowerInvariant();
                    if (section is not ("goal" or "constraint" or "done" or "context")) continue;
                    var phrase = line[(colon + 1)..].Trim();
                    var weight = 2.0;
                    var eq = phrase.LastIndexOf('=');
                    if (eq >= 0 && double.TryParse(phrase[(eq + 1)..].Trim(), out var w))
                    {
                        weight = w;
                        phrase = phrase[..eq].Trim();
                    }
                    if (phrase.Length == 0) continue;
                    cues.Add((section, @"\b" + Regex.Escape(phrase) + @"\b", weight));
                }
            }
        }
        catch { /* a malformed rules file must never break dictation */ }
        return cues;
    }

    private static (string Brief, double Quality) BuildBrief(
        List<string> clauses, List<(string Section, string Pattern, double Weight)> cues, double threshold)
    {
        var goal = new List<string>();
        var constraints = new List<string>();
        var done = new List<string>();
        var context = new List<string>();
        for (var i = 0; i < clauses.Count; i++)
        {
            var c = clauses[i];
            // The opening clause is the goal until strong evidence says otherwise.
            var score = new Dictionary<string, double>
            { ["goal"] = i == 0 ? 2 : 0, ["constraint"] = 0, ["done"] = 0, ["context"] = 0 };
            foreach (var (section, pattern, weight) in cues)
            {
                if (Regex.IsMatch(c, pattern, RegexOptions.IgnoreCase)) score[section] += weight;
            }
            var best = new[] { "constraint", "done", "context" }.OrderByDescending(s => score[s]).First();
            // A clause only leaves Goal when its cue evidence clears the bar AND
            // beats its goal evidence — the never-misort policy in one line.
            if (score[best] >= threshold && score[best] > score["goal"])
            {
                (best switch { "constraint" => constraints, "done" => done, _ => context }).Add(c);
            }
            else
            {
                goal.Add(c);
            }
        }
        var quality = goal.Count == 0 ? -4.0 : 3.0;
        quality += new[] { constraints, done, context }.Count(b => b.Count > 0);
        foreach (var bucket in new[] { constraints, done, context })
        {
            if (bucket.Count > clauses.Count * 0.5) quality -= 2;
        }
        var output = new List<string>();
        if (goal.Count > 0) output.Add("Goal\n" + string.Join(' ', goal.Select(SentenceCased)));
        if (constraints.Count > 0) output.Add("Constraints\n" + string.Join('\n', constraints.Select(x => "- " + SentenceCased(x))));
        if (done.Count > 0) output.Add("Done when\n" + string.Join('\n', done.Select(x => "- " + SentenceCased(x))));
        if (context.Count > 0) output.Add("Context\n" + string.Join('\n', context.Select(x => "- " + SentenceCased(x))));
        return (string.Join("\n\n", output), quality);
    }

    private static string AgentBrief(string text)
    {
        var clauses = TaskClauses(text);
        if (clauses.Count == 0) return Professional(text);
        var cues = CueTable();
        var best = BuildBrief(clauses, cues, 3.0);
        var lenient = BuildBrief(clauses, cues, 2.0);
        if (lenient.Quality > best.Quality) best = lenient;
        return best.Brief.Length == 0 ? Professional(text) : best.Brief;
    }

    /// Expand: code cannot invent detail, so instead of padding it asks. The
    /// cleaned request plus the unstated dimensions as open questions.
    private static string Expand(string text)
    {
        var doneCues = new Regex(
            @"\b(?:done when|should (?:return|show|display|work|pass|see)|expect(?:ed)? to|so that|it works when|tests? pass|verify that)\b",
            RegexOptions.IgnoreCase);
        var constraintCues = new Regex(
            @"\b(?:don'?t|do not|shouldn'?t|should not|must not|never|avoid|without (?:breaking|touching)|keep (?:the|it|everything)|leave (?:the|it)|make sure|only touch)\b",
            RegexOptions.IgnoreCase);
        var edgeCues = new Regex(
            @"\b(?:empty|missing|invalid|malformed|edge case|error|fail)\b",
            RegexOptions.IgnoreCase);
        var cleaned = Professional(text);
        var questions = new List<string>();
        // Domain questions first — they are the sharpest ones (v8.12 parity).
        var domains = new (string Cue, string Question)[]
        {
            (@"\b(?:page|button|screen|form|modal|toggle|menu|dropdown|the ui)\b",
             "- What should the loading, empty, and error states look like?"),
            (@"\b(?:api|endpoint|route|webhook|request|server)\b",
             "- What are the auth, rate limit, and error response expectations?"),
            (@"\b(?:bug|broken|crash|doesn'?t work|not working)\b",
             "- What are the exact steps that reproduce it, and what should happen instead?"),
            (@"\b(?:database|table|migration|schema|column)\b",
             "- Does anything need migrating, and what happens to existing rows?"),
            (@"\b(?:payment|checkout|billing|stripe|subscription|invoice)\b",
             "- What should happen on a failed, disputed, or refunded payment?"),
            (@"\b(?:login|log in|signup|sign up|auth|password|session)\b",
             "- Which users does this apply to, and what happens to existing sessions?"),
            (@"\b(?:slow|laggy|lag|latency|speed up|performance|faster|quicker)\b",
             "- What is the acceptable number, concretely: how fast is fast enough?"),
            (@"\b(?:deploy|release|ship it|rollout|roll out)\b",
             "- Is there a rollout order or migration involved, and is rollback required?"),
            (@"\b(?:email|outreach|message to|reach out|follow up with)\b",
             "- Who exactly is the recipient, what tone, and what is the one thing they should do after reading?"),
            (@"\b(?:post|video|caption|tweet|blog|content)\b",
             "- Which platform and audience is this for, and how long should it be?"),
            (@"\b(?:report|export|csv|spreadsheet|analytics|dashboard)\b",
             "- Which columns or metrics, over what time period, in what format?"),
            (@"\b(?:test|tests|coverage)\b",
             "- Which behaviors must be covered, and what counts as passing?"),
        };
        foreach (var (cue, question) in domains)
        {
            if (Regex.IsMatch(text, cue, RegexOptions.IgnoreCase)) questions.Add(question);
            if (questions.Count >= 2) break;
        }
        var domainMatched = questions.Count > 0;
        if (!doneCues.IsMatch(text)) questions.Add("- What does done look like, concretely?");
        if (!domainMatched && !edgeCues.IsMatch(text))
            questions.Add("- What should happen when the input is empty, missing, or malformed?");
        if (!constraintCues.IsMatch(text)) questions.Add("- Is there anything that must not change?");
        return questions.Count == 0 ? cleaned : cleaned + "\n\nOpen questions:\n" + string.Join('\n', questions);
    }
}

/// <summary>
/// Shared per-dictation state: which app the current or most recent recording
/// targets, and whether a mode was explicitly picked during it. Written by the
/// daemon at recording start and tray-menu click, read by the mode router.
/// </summary>
internal static class DictationSession
{
    public static string LastApp = "";
    public static bool ModePickedThisRecording;
}

/// <summary>
/// Per-app mode habits (v8.12, mirrors the Mac build's mode-usage file): every
/// explicit tray Mode pick is recorded against the app being dictated into.
/// Three-plus picks with a 60% majority make that mode the app's default.
/// </summary>
internal static class ModeHabits
{
    private static string FilePath => Path.Combine(AppPaths.Create().Root, "mode-usage");

    public static void Record(string app, string mode)
    {
        try
        {
            File.AppendAllText(FilePath, app + "\t" + mode + "\n");
            var lines = File.ReadAllLines(FilePath);
            if (lines.Length > 1000) File.WriteAllLines(FilePath, lines[^500..]);
        }
        catch { /* habit tracking must never break dictation */ }
    }

    public static string? Learned(string app)
    {
        try
        {
            if (string.IsNullOrEmpty(app) || !File.Exists(FilePath)) return null;
            var counts = new Dictionary<string, int>();
            var total = 0;
            foreach (var line in File.ReadAllLines(FilePath).TakeLast(200))
            {
                var parts = line.Split('\t');
                if (parts.Length != 2 || !parts[0].Equals(app, StringComparison.OrdinalIgnoreCase)) continue;
                counts[parts[1]] = counts.GetValueOrDefault(parts[1]) + 1;
                total++;
            }
            if (total < 3) return null;
            var top = counts.OrderByDescending(kv => kv.Value).First();
            return top.Value >= total * 0.6 ? top.Key : null;
        }
        catch { return null; }
    }
}
