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
        (new Regex(@"\bim\b", RegexOptions.Compiled), "I'm"),
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

    private static List<string> CleanedSentences(string text) =>
        SplitSentences(text)
            .Select(s => FixContractions(StripSpokenFiller(ResolveSelfCorrections(s))))
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

    /// Professional: the speaker's own words, minus the junk, cased and punctuated.
    private static string Professional(string text) =>
        string.Join(' ', CleanedSentences(text).Select(SentenceCased));

    /// Summarize: structure without condensing. Enumeration leads become a
    /// dashed list, topic shifts start a new paragraph. Nothing is dropped.
    private static string Summarize(string text)
    {
        var listLead = new Regex(
            @"^(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|then|next|also|finally|lastly|on top of that|number \w+)[,]?\s+",
            RegexOptions.IgnoreCase);
        var topicShift = new Regex(
            @"^(?:anyway|separately|one more thing|oh and|on another note)[,]?\s+",
            RegexOptions.IgnoreCase);
        var blocks = new List<string>();
        var para = new List<string>();
        var list = new List<string>();
        void FlushPara() { if (para.Count > 0) { blocks.Add(string.Join(' ', para)); para.Clear(); } }
        void FlushList() { if (list.Count > 0) { blocks.Add(string.Join('\n', list.Select(x => "- " + x))); list.Clear(); } }
        foreach (var s in CleanedSentences(text))
        {
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
            ("goal", @"^(?:please\s+)?(?:add|fix|build|make|create|update|change|remove|delete|implement|wire|write|move|rename|refactor|redesign|set up|hook up|clean up)\b", 3),
            ("goal", @"\b(?:i (?:want|need) (?:you )?to|can you|we need to|the goal is|i'?m trying to)\b", 3),
            ("goal", @"\b(?:it should|it needs to|there should be)\b", 1.5),
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
        if (!doneCues.IsMatch(text)) questions.Add("- What does done look like, concretely?");
        if (!edgeCues.IsMatch(text)) questions.Add("- What should happen when the input is empty, missing, or malformed?");
        if (!constraintCues.IsMatch(text)) questions.Add("- Is there anything that must not change?");
        return questions.Count == 0 ? cleaned : cleaned + "\n\nOpen questions:\n" + string.Join('\n', questions);
    }
}
