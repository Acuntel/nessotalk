using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PttDictate;

/// <summary>
/// AI polish via the nesso.tech server proxy. Mirrors the Mac build's polishForAI /
/// polishForText / polishViaProxy (apps/mac/ptt-dictate.swift): after transcription and
/// formatting, a licensed install may send the transcript to POLISH_PROXY_URL for a
/// summarize or professional rewrite. Any error, timeout, empty response, or untrustworthy
/// rewrite falls back to the raw transcript, so dictation never blocks and never loses
/// the user's words.
/// </summary>
internal static class PolishClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private static readonly Regex LeadingVerbatim = new(@"^(?i:verbatim)[,.]?\s*", RegexOptions.Compiled);

    /// <summary>
    /// Returns the text that should be pasted: either <paramref name="text"/> unchanged,
    /// or a polished rewrite from the proxy.
    /// </summary>
    public static string Apply(string text, AppConfig config)
    {
        var verbatimMatch = LeadingVerbatim.Match(text);
        if (verbatimMatch.Success)
        {
            // A spoken leading "verbatim" always forces the raw transcript, license or not.
            return text[verbatimMatch.Length..];
        }

        if (!LicenseManager.IsLicensed) return text;

        var words = CountWords(text);
        if (words < config.PolishMinWords) return text;

        var mode = SelectMode(config);
        if (mode == "normal") return text;

        var timeoutSeconds = mode switch
        {
            "summarize" => Math.Max(30, words / 4.0),
            "agent" or "expand" => Math.Max(45, words / 4.0),   // agent runs at high effort
            _ => Math.Max(25, words / 5.0)
        };
        var polished = CallProxy(text, mode, TimeSpan.FromSeconds(timeoutSeconds), config);
        if (polished is null)
        {
            Log.Info($"Polish ({mode}) unreachable; applying the built-in code {mode} instead.");
            return LocalModes.Transform(text, mode);
        }

        if (!PassesTrustGate(mode, text, polished))
        {
            Log.Info($"Polish ({mode}) result failed the trust gate; applying the built-in code {mode} instead.");
            return LocalModes.Transform(text, mode);
        }

        return polished;
    }

    // PRO_APPS/POLISH_APPS are matched against the foreground process name the same way
    // the Mac build matches bundle ids against PRO_APPS/POLISH_APPS: a case-insensitive
    // substring match against each comma-separated entry. Mirrors the Mac build's actual
    // mode switch: a PRO_APPS match always forces the professional rewrite, UNLESS the
    // foreground app also matches POLISH_APPS (an AI/coding tool), in which case
    // DEFAULT_MODE decides instead. Everywhere else, DEFAULT_MODE decides.
    private static string SelectMode(AppConfig config)
    {
        // v8.12 Mac-parity ordering: a mode picked DURING this recording wins,
        // then this app's learned habit, then the sticky remembered mode, then
        // the app-based routing, then DEFAULT_MODE.
        if (config.SelectedMode != "ask" && DictationSession.ModePickedThisRecording)
            return config.SelectedMode;
        var foreground = ForegroundProcessName();
        var learned = ModeHabits.Learned(foreground);
        if (learned is not null && learned != config.SelectedMode)
        {
            Log.Info($"Learned mode for {foreground}: {learned} (your usual pick here)");
            return learned;
        }
        if (config.SelectedMode != "ask") return config.SelectedMode;
        var aiTarget = MatchesAppList(foreground, config.PolishApps);
        var proTarget = MatchesAppList(foreground, config.ProApps);
        if (proTarget && !aiTarget) return "professional";
        return config.DefaultMode;
    }

    private static bool MatchesAppList(string processName, string appList)
    {
        if (string.IsNullOrWhiteSpace(processName) || string.IsNullOrWhiteSpace(appList)) return false;
        var name = processName.ToLowerInvariant();
        foreach (var token in appList.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (name.Contains(token.ToLowerInvariant())) return true;
        }
        return false;
    }

    internal static string ForegroundProcessName()
    {
        try
        {
            var hwnd = NativeMethods.GetForegroundWindow();
            NativeMethods.GetWindowThreadProcessId(hwnd, out var pid);
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception ex)
        {
            Log.Info($"Could not read the foreground process name: {ex.Message}");
            return "";
        }
    }

    // Trust gates matching the Mac build: a refusal/meta answer or a rewrite that lost too
    // much content means we paste the user's own words instead of the model's output.
    private static bool PassesTrustGate(string mode, string input, string output)
    {
        var trimmed = output.Trim();
        if (trimmed.Length == 0) return false;

        var lower = trimmed.ToLowerInvariant();
        if (lower.StartsWith("i can't") || lower.StartsWith("i cannot") || lower.StartsWith("i'm sorry")
            || lower.StartsWith("here is the rewritten") || lower.StartsWith("here's the rewritten"))
        {
            return false;
        }

        // Agent/Extend briefs restructure rather than preserve, so a length ratio would
        // reject legitimate output (the Mac build applies no length gate there either).
        if (mode is "agent" or "expand") return true;

        return mode == "summarize"
            ? trimmed.Length >= input.Length * 3 / 5
            : trimmed.Length >= input.Length / 2;
    }

    private static string? CallProxy(string text, string mode, TimeSpan timeout, AppConfig config)
    {
        try
        {
            var payload = JsonSerializer.Serialize(new { key = config.LicenseKey, mode, text });
            using var request = new HttpRequestMessage(HttpMethod.Post, config.PolishProxyUrl)
            {
                Content = new StringContent(payload, Encoding.UTF8, "application/json")
            };
            using var cts = new CancellationTokenSource(timeout);
            using var response = Http.Send(request, cts.Token);
            using var stream = response.Content.ReadAsStream();
            using var doc = JsonDocument.Parse(stream);
            var root = doc.RootElement;

            if (root.TryGetProperty("error", out _)) return null;
            if (!response.IsSuccessStatusCode) return null;
            if (!root.TryGetProperty("text", out var textProp)) return null;

            var result = textProp.GetString();
            return string.IsNullOrWhiteSpace(result) ? null : result;
        }
        catch (Exception ex)
        {
            Log.Info($"Polish proxy request failed: {ex.Message}");
            return null;
        }
    }

    private static int CountWords(string text) => text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
}
