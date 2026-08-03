using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace PttDictate;

/// <summary>
/// Lease check-in against the nesso.tech license server. Mirrors the Mac build's
/// "lease check-in" (apps/mac/ptt-dictate.swift, checkLicense/tokenAccepted): on startup
/// and every 12 hours the daemon posts this machine's id and the configured LICENSE_KEY.
/// A valid response carries an Ed25519-signed token that is verified here against the
/// nesso.tech public key, then cached to disk so the app keeps working if the server is
/// briefly unreachable. Recording refuses to start while unlicensed; an in-flight
/// recording is always allowed to finish (see DictationContext.StartRecording).
/// </summary>
internal static class LicenseManager
{
    private const string PublicKeyBase64 = "DgOqB8kIOGQDePmlGSFcbZVVbujNZ9CVM+XkPFSJZjw=";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(2) };
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(12);
    private static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(15);

    private static AppConfig? _config;
    private static AppPaths? _paths;
    // Keeps the recheck timer alive; a local variable would be garbage collected.
    private static System.Threading.Timer? _timer;

    // Optimistic default while the very first check-in is still in flight, matching the
    // Mac daemon's `var licenseValid = true` starting value: a brand-new launch does not
    // disarm recording before the first network round trip has had a chance to complete.
    private static volatile bool _licensed = true;

    public static bool IsLicensed => _licensed;

    public static void Start(AppConfig config, AppPaths paths)
    {
        _config = config;
        _paths = paths;
        _ = Task.Run(CheckNow);
        _timer = new System.Threading.Timer(_ => CheckNow(), null, CheckInterval, CheckInterval);
    }

    private static void CheckNow()
    {
        var config = _config;
        var paths = _paths;
        if (config is null || paths is null) return;

        if (string.IsNullOrEmpty(config.LicenseKey))
        {
            // A ".dev" marker file next to the config, which ships in no build, keeps a
            // development machine running without a license key.
            if (File.Exists(Path.Combine(paths.Root, ".dev")))
            {
                _licensed = true;
                return;
            }
            _licensed = false;
            Log.Info("No license key is configured. Sign in at nesso.tech and download your copy to activate.");
            return;
        }

        try
        {
            var machine = MachineId.Get();
            var payload = JsonSerializer.Serialize(new { key = config.LicenseKey, machine });
            using var request = new HttpRequestMessage(HttpMethod.Post, config.LicenseUrl)
            {
                Content = new StringContent(payload, Encoding.UTF8, "application/json")
            };
            using var cts = new CancellationTokenSource(RequestTimeout);
            using var response = Http.Send(request, cts.Token);
            using var stream = response.Content.ReadAsStream();
            using var doc = JsonDocument.Parse(stream);
            var root = doc.RootElement;

            if (!root.TryGetProperty("token", out var tokenProp) || !root.TryGetProperty("sig", out var sigProp))
            {
                ApplyCachedToken(config, paths);
                return;
            }

            var token = tokenProp.GetString() ?? "";
            var sig = sigProp.GetString() ?? "";
            if (TokenAccepted(token, sig, config))
            {
                _licensed = true;
                File.WriteAllText(TokenPath(paths), $"{token}\n{sig}");
            }
            else
            {
                _licensed = false;
                var reason = root.TryGetProperty("reason", out var reasonProp) ? reasonProp.GetString() : "signature rejected";
                Log.Info($"License inactive ({reason}). Dictation is disarmed. Manage it at nesso.tech.");
            }
        }
        catch (Exception ex)
        {
            Log.Info($"License check-in failed, falling back to the cached token: {ex.Message}");
            ApplyCachedToken(config, paths);
        }
    }

    // No answer from the server: fall back to the last signed token we stored, honoring
    // its own expiry offline.
    private static void ApplyCachedToken(AppConfig config, AppPaths paths)
    {
        var path = TokenPath(paths);
        if (!File.Exists(path))
        {
            _licensed = false;
            Log.Info("No cached license and the server is unreachable. Dictation is disarmed.");
            return;
        }

        var raw = File.ReadAllText(path);
        var parts = raw.Split('\n', 2);
        if (parts.Length == 2 && TokenAccepted(parts[0].Trim(), parts[1].Trim(), config))
        {
            _licensed = true;
        }
        else
        {
            _licensed = false;
            Log.Info("The cached license expired and the server is unreachable. Dictation is disarmed.");
        }
    }

    // True only if the signature is genuine AND the payload names this key and machine,
    // says valid, and has not expired.
    private static bool TokenAccepted(string token, string sig, AppConfig config)
    {
        try
        {
            var tokenBytes = Convert.FromBase64String(token);
            var sigBytes = Convert.FromBase64String(sig);
            var publicKeyBytes = Convert.FromBase64String(PublicKeyBase64);
            if (!Ed25519Verify.Verify(publicKeyBytes, tokenBytes, sigBytes)) return false;

            using var doc = JsonDocument.Parse(tokenBytes);
            var root = doc.RootElement;
            if (!root.TryGetProperty("valid", out var validProp) || validProp.ValueKind != JsonValueKind.True) return false;
            if (!root.TryGetProperty("key", out var keyProp) || keyProp.GetString() != config.LicenseKey) return false;
            if (!root.TryGetProperty("exp", out var expProp)) return false;

            var exp = expProp.GetDouble();
            if (exp <= DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()) return false;

            var machine = root.TryGetProperty("machine", out var machineProp) ? machineProp.GetString() ?? "" : "";
            return machine.Length == 0 || machine == MachineId.Get();
        }
        catch
        {
            return false;
        }
    }

    private static string TokenPath(AppPaths paths) => Path.Combine(paths.Root, ".license_token");
}

/// <summary>
/// Stable per-machine id used to bind a license seat, mirroring the Mac build's
/// IOPlatformUUID. Windows has no equivalent per-machine hardware UUID exposed to
/// user-mode apps without WMI, so the registry MachineGuid (written once when Windows is
/// installed) is the closest analog. If the registry is unreadable for any reason, a
/// hash of the machine and user name is a stable-enough fallback.
/// </summary>
internal static class MachineId
{
    public static string Get()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            if (key?.GetValue("MachineGuid") is string guid && !string.IsNullOrWhiteSpace(guid))
                return guid;
        }
        catch (Exception ex)
        {
            Log.Info($"Could not read the registry MachineGuid; using the fallback machine id: {ex.Message}");
        }

        var seed = $"{Environment.MachineName}|{Environment.UserName}";
        var hash = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(seed));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}
