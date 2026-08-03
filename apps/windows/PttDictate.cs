using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Automation;
using System.Windows.Forms;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace PttDictate;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        var paths = AppPaths.Create();
        var needsStorage = args.Length == 0 || args[0].Equals("--daemon", StringComparison.OrdinalIgnoreCase) ||
            args[0].Equals("--miccheck", StringComparison.OrdinalIgnoreCase) ||
            args[0].Equals("--transcribe-file", StringComparison.OrdinalIgnoreCase);
        if (needsStorage)
        {
            Directory.CreateDirectory(paths.Root);
            Directory.CreateDirectory(paths.Recordings);
        }
        Log.Initialize(needsStorage ? paths.Log : Path.Combine(Path.GetTempPath(), "ptt-dictate.log"));
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Log.Error("Unhandled UI error", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log.Error("Unhandled process error", e.ExceptionObject as Exception ?? new Exception(e.ExceptionObject?.ToString()));
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error("Unobserved background error", e.Exception);
            e.SetObserved();
        };
        var config = AppConfig.Load(paths.Config, paths);

        try
        {
            if (args.Length > 0)
            {
                return RunCommand(args, config, paths).GetAwaiter().GetResult();
            }

            return RunDaemon(config, paths);
        }
        catch (Exception ex)
        {
            Log.Error("Fatal error", ex);
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static async Task<int> RunCommand(string[] args, AppConfig config, AppPaths paths)
    {
        switch (args[0].ToLowerInvariant())
        {
            case "--daemon":
                return RunDaemon(config, paths);
            case "--format-stdin":
                Console.OutputEncoding = Encoding.UTF8;
                Console.Write(TextFormatter.Format(await Console.In.ReadToEndAsync(), config.Glossary));
                return 0;
            case "--transcribe-file" when args.Length >= 2:
                var transcript = await new WhisperTranscriber(config, paths).TranscribeAsync(
                    Path.GetFullPath(args[1]), CancellationToken.None);
                Console.OutputEncoding = Encoding.UTF8;
                Console.WriteLine(TextFormatter.Format(transcript, config.Glossary));
                return 0;
            case "--miccheck":
                return await MicCheckAsync(config, paths);
            case "--devices":
                DeviceCatalog.Print();
                return 0;
            case "--send" when args.Length >= 2:
                var response = await IpcClient.SendAsync(string.Join(' ', args.Skip(1)), TimeSpan.FromSeconds(3));
                Console.WriteLine(response);
                return response.StartsWith("error", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            case "--self-test":
                return SelfTests.Run();
            case "--paste-self-test":
                return PasteIntegrationTest.Run();
            case "--cleanup-completed":
                Console.WriteLine($"Deleted {RecordingCleanup.DeleteAllCompleted(paths.Recordings)} completed recording artifact(s).");
                return 0;
            case "--sound-demo":
                await SoundCue.PlayDemoAsync(config.StartSound, config.StopSound, config.DoneSound);
                Console.WriteLine("Played start, stop, and done sounds.");
                return 0;
            default:
                Console.Error.WriteLine("Usage: ptt-dictate [--daemon | --devices | --miccheck | --transcribe-file WAV | --format-stdin | --send COMMAND | --self-test | --paste-self-test | --cleanup-completed | --sound-demo]");
                return 2;
        }
    }

    private static int RunDaemon(AppConfig config, AppPaths paths)
    {
        using var mutex = new Mutex(true, @"Local\ptt-dictate-single-instance", out var created);
        if (!created)
        {
            Console.Error.WriteLine("ptt-dictate is already running.");
            return 3;
        }

        Log.Info($"Starting ptt-dictate; hotkey={config.Hotkey}; root={paths.Root}");
        using var context = new DictationContext(config, paths);
        Application.Run(context);
        Log.Info("Stopped ptt-dictate");
        return 0;
    }

    private static async Task<int> MicCheckAsync(AppConfig config, AppPaths paths)
    {
        Console.WriteLine($"Recording {config.MicCheckSeconds} seconds. Speak now...");
        var file = Path.Combine(paths.Recordings, $"miccheck-{DateTime.Now:yyyyMMdd-HHmmss}.wav");
        await using var recorder = new AudioRecorder(config, paths);
        recorder.Start(file);
        await Task.Delay(TimeSpan.FromSeconds(config.MicCheckSeconds));
        var result = await recorder.StopAsync();
        Console.WriteLine($"Captured {result.Duration.TotalSeconds:F1}s from {result.DeviceName}; peak={result.Peak:P0}");
        if (result.FrameBytes == 0)
        {
            Console.Error.WriteLine("No microphone frames were captured.");
            return 1;
        }

        var transcript = await new WhisperTranscriber(config, paths).TranscribeAsync(result.WavPath, CancellationToken.None);
        Console.WriteLine(TextFormatter.Format(transcript, config.Glossary));
        return 0;
    }
}

internal sealed record AppPaths(string Root, string Config, string Log, string Recordings)
{
    public static AppPaths Create()
    {
        var overrideRoot = Environment.GetEnvironmentVariable("PTT_DICTATE_HOME");
        var root = string.IsNullOrWhiteSpace(overrideRoot)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ptt-dictate")
            : Path.GetFullPath(Environment.ExpandEnvironmentVariables(overrideRoot));
        return new(root, Path.Combine(root, "config"), Path.Combine(root, "ptt.log"), Path.Combine(root, "recordings"));
    }
}

internal sealed class AppConfig
{
    private readonly Dictionary<string, string> _values;
    private readonly AppPaths _paths;

    private AppConfig(Dictionary<string, string> values, AppPaths paths)
    {
        _values = values;
        _paths = paths;
    }

    public string Hotkey => Get("HOTKEY", "RightCtrl");
    public string InputDevice => Get("INPUT_DEVICE", "builtin");

    // MAX_RECORD_SECONDS is the canonical key (shared with the Mac build's config
    // schema). MAX_RECORD_MINUTES is still honored so existing installs that only set
    // the old key keep working.
    public int MaxRecordSeconds
    {
        get
        {
            if (_values.TryGetValue("MAX_RECORD_SECONDS", out var raw) && int.TryParse(raw, out var seconds))
                return Math.Clamp(seconds, 10, 10800);
            return GetInt("MAX_RECORD_MINUTES", 45, 1, 180) * 60;
        }
    }

    public int MicCheckSeconds => GetInt("MICCHECK_SECONDS", 5, 1, 30);
    public bool AutoPaste => GetBool("AUTO_PASTE", true);
    public bool PreprocessAudio => GetBoolWithFallback("PREPROCESS", "PREPROCESS_AUDIO", true);
    public string FfmpegPath => Expand(Get("FFMPEG_PATH", "ffmpeg.exe"));
    public string WhisperCli => Expand(Get("WHISPER_CLI", Path.Combine(_paths.Root, "whisper", "whisper-cli.exe")));
    public string WhisperModel => Expand(Get("WHISPER_MODEL", Path.Combine(_paths.Root, "models", "ggml-large-v3-turbo-q5_0.bin")));
    public string VadModel => Expand(Get("VAD_MODEL", Path.Combine(_paths.Root, "models", "ggml-silero-v6.2.0.bin")));
    public int WhisperTimeoutSeconds => GetInt("WHISPER_TIMEOUT_SECONDS", 600, 10, 3600);
    public string WhisperLanguage => GetWithFallback("LANGUAGE", "WHISPER_LANGUAGE", "en");
    // Whisper mode: quiet-voice dictation. Lowers the whisper.cpp VAD threshold so soft
    // speech is not gated out (a lighter-weight analog of the Mac build's whisper-mode
    // gain/VAD tuning; see WhisperTranscriber.TranscribeAsync).
    public bool WhisperMode => GetBool("WHISPER_MODE", false);
    public int WhisperThreads => GetInt("WHISPER_THREADS", 0, 0, 256);
    public string WhisperPrompt => PromptLimiter.Limit(Get("WHISPER_PROMPT", "Wispr Flow, ptt-dictate, Codex, Next.js, TypeScript, PowerShell, Windows, whisper.cpp."));
    public string Glossary => Get("GLOSSARY", "");
    public string StartSound => Expand(Get("START_SOUND", ""));
    public string StopSound => Expand(Get("STOP_SOUND", ""));
    public string DoneSound => Expand(Get("DONE_SOUND", ""));

    // License / lease check-in (see License.cs). Empty LICENSE_KEY means unlicensed
    // unless a ".dev" file sits next to the config.
    public string LicenseKey => Get("LICENSE_KEY", "");
    public string LicenseUrl => Get("LICENSE_URL", "https://nesso.tech/api/license");

    // AI polish via the nesso.tech server proxy (see Polish.cs).
    public string PolishProxyUrl => Get("POLISH_PROXY_URL", "https://nesso.tech/api/polish");
    public string DefaultMode => NormalizeMode(Get("DEFAULT_MODE", "summarize"));
    public string Style => Get("STYLE", "");
    public string ProApps => Get("PRO_APPS", "OUTLOOK,Teams,slack,discord,WhatsApp");
    public string PolishApps => Get("POLISH_APPS", "WindowsTerminal,Code,Cursor,Warp,Claude,Codex");
    public int PolishMinWords => GetInt("POLISH_MIN_WORDS", 12, 1, 100000);

    public static AppConfig Load(string path, AppPaths paths)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (File.Exists(path))
        {
            foreach (var raw in File.ReadAllLines(path))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#')) continue;
                var equals = line.IndexOf('=');
                if (equals <= 0) continue;
                values[line[..equals].Trim()] = line[(equals + 1)..].Trim();
            }
        }
        else
        {
            Log.Info($"Config not found at {path}; using defaults");
        }

        return new AppConfig(values, paths);
    }

    private string Get(string key, string fallback) => _values.TryGetValue(key, out var value) ? value : fallback;
    private bool GetBool(string key, bool fallback) => bool.TryParse(Get(key, fallback.ToString()), out var value) ? value : fallback;
    private int GetInt(string key, int fallback, int min, int max) => int.TryParse(Get(key, fallback.ToString(CultureInfo.InvariantCulture)), out var value) ? Math.Clamp(value, min, max) : fallback;
    private static string Expand(string value) => Environment.ExpandEnvironmentVariables(value.Trim().Trim('"'));

    // Reads primaryKey if set, otherwise falls back to a legacy key name, so renaming a
    // config key to match the Mac build's schema does not break an existing install that
    // only set the old name.
    private string GetWithFallback(string primaryKey, string fallbackKey, string fallbackValue)
    {
        if (_values.TryGetValue(primaryKey, out var primary) && !string.IsNullOrWhiteSpace(primary)) return primary;
        if (_values.TryGetValue(fallbackKey, out var legacy) && !string.IsNullOrWhiteSpace(legacy)) return legacy;
        return fallbackValue;
    }

    private bool GetBoolWithFallback(string primaryKey, string fallbackKey, bool fallbackValue) =>
        bool.TryParse(GetWithFallback(primaryKey, fallbackKey, fallbackValue.ToString()), out var value) ? value : fallbackValue;

    private static string NormalizeMode(string value)
    {
        var normalized = value.Trim().ToLowerInvariant();
        return normalized is "summarize" or "professional" or "normal" ? normalized : "summarize";
    }
}

internal static class PromptLimiter
{
    public static string Limit(string prompt)
    {
        // English prose averages roughly 1.3 tokens/word. A 165-word cap stays below
        // whisper.cpp's approximately 220-token initial-prompt limit.
        var words = Regex.Matches(prompt, @"\S+").Select(m => m.Value).Take(165).ToArray();
        return string.Join(' ', words);
    }
}

internal sealed class DictationContext : ApplicationContext
{
    private readonly AppConfig _config;
    private readonly AppPaths _paths;
    private readonly NotifyIcon _tray;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _toggleItem;
    private readonly System.Drawing.Icon _readyIcon;
    private readonly System.Drawing.Icon _recordingIcon;
    private readonly System.Drawing.Icon _processingIcon;
    private readonly Control _invoker;
    private readonly InputHooks _hooks;
    private readonly IpcServer _ipc;
    private readonly WhisperTranscriber _transcriber;
    private readonly DictationOverlay _overlay;
    private AudioRecorder? _recorder;
    private System.Threading.Timer? _recordingCap;
    private bool _processing;

    public DictationContext(AppConfig config, AppPaths paths)
    {
        _config = config;
        _paths = paths;
        RecordingCleanup.DeleteAllCompleted(_paths.Recordings);
        _transcriber = new WhisperTranscriber(config, paths);
        _invoker = new Control();
        _invoker.CreateControl();
        _overlay = new DictationOverlay();

        _readyIcon = TrayIcons.Create(System.Drawing.Color.FromArgb(36, 167, 110));
        _recordingIcon = TrayIcons.Create(System.Drawing.Color.FromArgb(220, 53, 69));
        _processingIcon = TrayIcons.Create(System.Drawing.Color.FromArgb(245, 166, 35));

        var menu = new ContextMenuStrip();
        _statusItem = new ToolStripMenuItem("Status: Ready") { Enabled = false };
        _toggleItem = new ToolStripMenuItem("Start recording", null, (_, _) => ToggleRecording());
        menu.Items.Add(_statusItem);
        menu.Items.Add(_toggleItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Settings...", null, (_, _) => OpenConfig());
        menu.Items.Add("Recordings folder", null, (_, _) => OpenPath(_paths.Recordings));
        menu.Items.Add("View log", null, (_, _) => OpenLog());
        menu.Items.Add("Test sounds", null, async (_, _) => await SoundCue.PlayDemoAsync(_config.StartSound, _config.StopSound, _config.DoneSound));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("About ptt-dictate", null, (_, _) => ShowAbout());
        menu.Items.Add("Exit", null, (_, _) => ExitThread());
        _tray = new NotifyIcon
        {
            Icon = _readyIcon,
            Text = "ptt-dictate — Ready",
            ContextMenuStrip = menu,
            Visible = true
        };
        _tray.DoubleClick += (_, _) => ToggleRecording();

        _hooks = new InputHooks(config.Hotkey, () => _invoker.BeginInvoke(ToggleRecording),
            () => _recorder is not null, () => _invoker.BeginInvoke(CancelRecording));
        _hooks.Install();
        _ipc = new IpcServer(HandleIpcAsync);
        _ipc.Start();
        LicenseManager.Start(config, paths);
        ShowBalloon("ptt-dictate is ready", $"Tap {config.Hotkey} to start or stop dictation. Press Escape to cancel a recording.");
    }

    private void ToggleRecording()
    {
        if (_processing)
        {
            Log.Info("Toggle ignored while transcription is already in progress");
            return;
        }

        if (_recorder is null) StartRecording();
        else _ = StopRecordingAsync("hotkey");
    }

    private void StartRecording()
    {
        if (!LicenseManager.IsLicensed)
        {
            Log.Info("Recording blocked: no active license");
            _overlay.ShowError("Not licensed. Visit nesso.tech to activate ptt-dictate.");
            SoundCue.PlayError();
            ShowBalloon("Not licensed", "Visit nesso.tech to activate your copy of ptt-dictate before dictating.");
            return;
        }

        try
        {
            var raw = Path.Combine(_paths.Recordings, $"dictation-{DateTime.Now:yyyyMMdd-HHmmss-fff}-raw.wav");
            _recorder = new AudioRecorder(_config, _paths);
            _recorder.Start(raw);
            _recordingCap = new System.Threading.Timer(_ => _invoker.BeginInvoke(() => _ = StopRecordingAsync("automatic safety cap")), null,
                TimeSpan.FromSeconds(_config.MaxRecordSeconds), Timeout.InfiniteTimeSpan);
            SetTrayState(DaemonState.Recording);
            _overlay.ShowListening();
            SoundCue.PlayStart(_config.StartSound);
            Log.Info("Recording started");
        }
        catch (Exception ex)
        {
            _recorder?.DisposeAsync().AsTask().GetAwaiter().GetResult();
            _recorder = null;
            Log.Error("Could not start recording", ex);
            _overlay.ShowError("Microphone unavailable");
            SoundCue.PlayError();
            ShowBalloon("Microphone error", ex.Message);
        }
    }

    // Escape cancels an in-progress recording outright: nothing is transcribed and
    // nothing is pasted. Has no effect once StopRecordingAsync has already taken over
    // (an in-flight transcription is always allowed to finish).
    private void CancelRecording()
    {
        if (_recorder is null) return;
        var recorder = _recorder;
        _recorder = null;
        _recordingCap?.Dispose();
        _recordingCap = null;
        SetTrayState(DaemonState.Ready);
        _overlay.HideImmediately();
        SoundCue.PlayError();
        Log.Info("Recording canceled with Escape; nothing was transcribed or pasted");
        _ = Task.Run(async () =>
        {
            try
            {
                var capture = await recorder.StopAsync();
                await recorder.DisposeAsync();
                File.Delete(capture.WavPath);
            }
            catch (Exception ex)
            {
                Log.Error("Could not clean up a canceled recording", ex);
            }
        });
    }

    private async Task StopRecordingAsync(string reason)
    {
        if (_recorder is null || _processing) return;
        _processing = true;
        var recorder = _recorder;
        _recorder = null;
        _recordingCap?.Dispose();
        _recordingCap = null;
        SetTrayState(DaemonState.Transcribing);
        _overlay.ShowTranscribing();
        SoundCue.PlayStop(_config.StopSound);
        Log.Info($"Recording stopped: {reason}");

        try
        {
            var capture = await recorder.StopAsync();
            await recorder.DisposeAsync();
            Log.Info($"Captured {capture.Duration.TotalSeconds:F1}s, {capture.FrameBytes} bytes, peak={capture.Peak:P1}, device={capture.DeviceName}");
            if (capture.FrameBytes == 0)
                throw new InvalidOperationException("The selected microphone produced zero frames. Run 'ptt devices' and choose another INPUT_DEVICE.");

            var raw = await Task.Run(() => _transcriber.TranscribeAsync(capture.WavPath, CancellationToken.None));
            var formatted = TextFormatter.Format(raw, _config.Glossary);
            RecordingCleanup.DeleteSuccessful(capture.WavPath);
            if (string.IsNullOrWhiteSpace(formatted))
            {
                Log.Info("No speech recognized; nothing will be pasted");
                _overlay.ShowNoSpeech();
                ShowBalloon("No speech recognized", "VAD filtered the recording, so nothing was pasted.");
                return;
            }

            formatted = await Task.Run(() => PolishClient.Apply(formatted, _config));

            if (!_config.AutoPaste)
            {
                Clipboard.SetText(formatted);
                _overlay.ShowDone("Copied to clipboard");
                ShowBalloon("Transcript copied", "AUTO_PASTE is disabled; the text is on your clipboard.");
            }
            else
            {
                try
                {
                    await ClipboardPaster.PasteAndRestoreAsync(formatted);
                    _overlay.ShowDone("Pasted into the active app");
                }
                catch (Exception ex)
                {
                    Clipboard.SetText(formatted);
                    _overlay.ShowDone("Copied to clipboard");
                    Log.Error("Auto-paste failed; transcript was left on the clipboard", ex);
                    ShowBalloon("Transcript copied", "Windows rejected automatic paste. Press Ctrl+V to paste the transcript.");
                }
            }
            SoundCue.PlayDone(_config.DoneSound);
        }
        catch (Exception ex)
        {
            Log.Error("Dictation failed", ex);
            _overlay.ShowError("Dictation failed — recording kept");
            SoundCue.PlayError();
            ShowBalloon("Dictation failed", ex.Message);
        }
        finally
        {
            _processing = false;
            SetTrayState(DaemonState.Ready);
        }
    }

    private async Task<string> HandleIpcAsync(string command)
    {
        var verb = command.Trim().ToLowerInvariant();
        if (verb == "status") return _recorder is not null ? "recording" : _processing ? "transcribing" : "ready";
        if (verb is "tap" or "toggle")
        {
            _invoker.BeginInvoke(ToggleRecording);
            return "ok: toggled";
        }
        if (verb == "stop")
        {
            _invoker.BeginInvoke(ExitThread);
            return "ok: stopping";
        }
        return await Task.FromResult("error: unknown command");
    }

    private void OpenLog()
    {
        try { Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_paths.Log}\"") { UseShellExecute = true }); }
        catch (Exception ex) { Log.Error("Could not open log", ex); }
    }

    private void OpenConfig()
    {
        try
        {
            if (!File.Exists(_paths.Config)) File.WriteAllText(_paths.Config, "# ptt-dictate settings\n");
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{_paths.Config}\"") { UseShellExecute = true });
        }
        catch (Exception ex) { Log.Error("Could not open settings", ex); }
    }

    private static void OpenPath(string path)
    {
        try
        {
            Directory.CreateDirectory(path);
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex) { Log.Error("Could not open folder", ex); }
    }

    private void ShowAbout()
    {
        MessageBox.Show(
            $"ptt-dictate 1.0\n\nPrivate, local push-to-talk dictation for Windows.\n\nHotkey: {_config.Hotkey}\nMicrophone: {_config.InputDevice}\nTranscription: whisper.cpp with Silero VAD",
            "About ptt-dictate", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    private void SetTrayState(DaemonState state)
    {
        switch (state)
        {
            case DaemonState.Recording:
                _tray.Icon = _recordingIcon;
                _tray.Text = "ptt-dictate — Recording";
                _statusItem.Text = "Status: Recording";
                _toggleItem.Text = "Stop recording";
                _toggleItem.Enabled = true;
                break;
            case DaemonState.Transcribing:
                _tray.Icon = _processingIcon;
                _tray.Text = "ptt-dictate — Transcribing";
                _statusItem.Text = "Status: Transcribing";
                _toggleItem.Text = "Transcribing...";
                _toggleItem.Enabled = false;
                break;
            default:
                _tray.Icon = _readyIcon;
                _tray.Text = "ptt-dictate — Ready";
                _statusItem.Text = "Status: Ready";
                _toggleItem.Text = "Start recording";
                _toggleItem.Enabled = true;
                break;
        }
    }

    private void ShowBalloon(string title, string text)
    {
        _tray.BalloonTipTitle = title;
        _tray.BalloonTipText = text.Length > 240 ? text[..240] : text;
        _tray.ShowBalloonTip(3000);
    }

    protected override void ExitThreadCore()
    {
        _recordingCap?.Dispose();
        _hooks.Dispose();
        _ipc.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _readyIcon.Dispose();
        _recordingIcon.Dispose();
        _processingIcon.Dispose();
        _overlay.Dispose();
        _invoker.Dispose();
        base.ExitThreadCore();
    }
}

internal enum DaemonState
{
    Ready,
    Recording,
    Transcribing
}

internal static class RecordingCleanup
{
    public static int DeleteSuccessful(string rawWavPath)
    {
        var deleted = 0;
        try
        {
            var directory = Path.GetDirectoryName(rawWavPath);
            if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory)) return 0;
            var stem = Path.GetFileNameWithoutExtension(rawWavPath);
            foreach (var path in Directory.EnumerateFiles(directory, stem + "*"))
            {
                var extension = Path.GetExtension(path);
                if (!extension.Equals(".wav", StringComparison.OrdinalIgnoreCase) &&
                    !extension.Equals(".txt", StringComparison.OrdinalIgnoreCase)) continue;
                File.Delete(path);
                deleted++;
            }
            Log.Info($"Deleted {deleted} successful recording artifact(s) for {Path.GetFileName(rawWavPath)}");
        }
        catch (Exception ex)
        {
            Log.Error("Could not delete successful recording artifacts", ex);
        }
        return deleted;
    }

    public static int DeleteAllCompleted(string recordingsDirectory)
    {
        if (!Directory.Exists(recordingsDirectory)) return 0;
        var deleted = 0;
        const string suffix = "-16k-transcript.txt";
        foreach (var transcript in Directory.EnumerateFiles(recordingsDirectory, "dictation-*-raw-16k-transcript.txt").ToArray())
        {
            if (!transcript.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
            var rawPath = transcript[..^suffix.Length] + ".wav";
            deleted += DeleteSuccessful(rawPath);
        }
        return deleted;
    }
}

internal enum OverlayState
{
    Listening,
    Transcribing,
    Done,
    NoSpeech,
    Error
}

internal sealed class DictationOverlay : Form
{
    private readonly System.Windows.Forms.Timer _animationTimer;
    private readonly Stopwatch _recordingTime = new();
    private OverlayState _state;
    private string _detail = "";
    private DateTime _hideAt;
    private int _frame;

    public DictationOverlay()
    {
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = System.Drawing.Color.FromArgb(20, 22, 27);
        Text = "ptt-dictate status";
        AccessibleName = "ptt-dictate status";
        ClientSize = new System.Drawing.Size(360, 82);
        ControlBox = false;
        FormBorderStyle = FormBorderStyle.None;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowIcon = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        Opacity = 0.97;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        _animationTimer = new System.Windows.Forms.Timer { Interval = 80 };
        _animationTimer.Tick += (_, _) =>
        {
            _frame++;
            if ((_state is OverlayState.Done or OverlayState.NoSpeech or OverlayState.Error) && DateTime.UtcNow >= _hideAt)
            {
                Hide();
                _animationTimer.Stop();
            }
            else Invalidate();
        };
    }

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            const int wsExToolWindow = 0x00000080;
            const int wsExNoActivate = 0x08000000;
            var parameters = base.CreateParams;
            parameters.ExStyle |= wsExToolWindow | wsExNoActivate;
            return parameters;
        }
    }

    public void ShowListening()
    {
        _recordingTime.Restart();
        ShowState(OverlayState.Listening, "Right Ctrl to finish", TimeSpan.Zero);
    }

    public void ShowTranscribing()
    {
        _recordingTime.Stop();
        ShowState(OverlayState.Transcribing, "Processing locally", TimeSpan.Zero);
    }

    public void ShowDone(string detail) => ShowState(OverlayState.Done, detail, TimeSpan.FromSeconds(1.8));
    public void ShowNoSpeech() => ShowState(OverlayState.NoSpeech, "No speech detected", TimeSpan.FromSeconds(2.2));
    public void ShowError(string detail) => ShowState(OverlayState.Error, detail, TimeSpan.FromSeconds(3));

    // Used for an outright cancel (Escape): stop the animation and hide immediately,
    // instead of animating through a Done/Error state that implies something was pasted.
    public void HideImmediately()
    {
        _animationTimer.Stop();
        Hide();
    }

    private void ShowState(OverlayState state, string detail, TimeSpan visibleFor)
    {
        _state = state;
        _detail = detail;
        var accessibleState = state switch
        {
            OverlayState.Listening => "Listening",
            OverlayState.Transcribing => "Transcribing",
            OverlayState.Done => "Done",
            OverlayState.NoSpeech => "No speech detected",
            _ => "Error"
        };
        Text = $"ptt-dictate — {accessibleState}";
        AccessibleName = Text;
        AccessibleDescription = detail;
        _frame = 0;
        _hideAt = visibleFor == TimeSpan.Zero ? DateTime.MaxValue : DateTime.UtcNow + visibleFor;
        PositionNearActiveScreen();
        if (!Visible) Show();
        NativeMethods.SetWindowPos(Handle, new nint(-1), Left, Top, Width, Height, 0x0010 | 0x0040);
        _animationTimer.Start();
        Invalidate();
    }

    private void PositionNearActiveScreen()
    {
        var screen = Screen.FromHandle(NativeMethods.GetForegroundWindow());
        var area = screen.WorkingArea;
        Location = new System.Drawing.Point(area.Left + (area.Width - Width) / 2, area.Bottom - Height - 36);
        using var path = RoundedRectangle(new System.Drawing.Rectangle(0, 0, Width, Height), 22);
        Region?.Dispose();
        Region = new System.Drawing.Region(path);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using var panel = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(20, 22, 27));
        using var border = new System.Drawing.Pen(System.Drawing.Color.FromArgb(56, 61, 70), 1);
        using var shape = RoundedRectangle(new System.Drawing.Rectangle(1, 1, Width - 3, Height - 3), 21);
        g.FillPath(panel, shape);
        g.DrawPath(border, shape);

        var accent = _state switch
        {
            OverlayState.Listening => System.Drawing.Color.FromArgb(244, 83, 98),
            OverlayState.Transcribing => System.Drawing.Color.FromArgb(245, 173, 56),
            OverlayState.Done => System.Drawing.Color.FromArgb(51, 202, 133),
            OverlayState.NoSpeech => System.Drawing.Color.FromArgb(132, 142, 158),
            _ => System.Drawing.Color.FromArgb(244, 83, 98)
        };
        using var accentBrush = new System.Drawing.SolidBrush(accent);
        g.FillEllipse(accentBrush, 18, 18, 46, 46);
        DrawStateGlyph(g, accent);

        using var titleFont = new System.Drawing.Font("Segoe UI Variable Display", 11.5f, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Point);
        using var detailFont = new System.Drawing.Font("Segoe UI Variable Text", 8.5f, System.Drawing.FontStyle.Regular, System.Drawing.GraphicsUnit.Point);
        using var titleBrush = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(245, 247, 250));
        using var detailBrush = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(158, 166, 180));
        var title = _state switch
        {
            OverlayState.Listening => "Listening",
            OverlayState.Transcribing => "Transcribing",
            OverlayState.Done => "Done",
            OverlayState.NoSpeech => "Nothing to dictate",
            _ => "Something went wrong"
        };
        g.DrawString(title, titleFont, titleBrush, 78, 17);
        g.DrawString(_state == OverlayState.Listening ? $"{_recordingTime.Elapsed:mm\\:ss}  •  {_detail}" : _detail, detailFont, detailBrush, 79, 45);
        if (_state is OverlayState.Listening or OverlayState.Transcribing) DrawActivity(g, accent);
    }

    private void DrawStateGlyph(System.Drawing.Graphics g, System.Drawing.Color accent)
    {
        using var whitePen = new System.Drawing.Pen(System.Drawing.Color.White, 2.4f)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round
        };
        if (_state == OverlayState.Done)
        {
            g.DrawLines(whitePen, [new System.Drawing.PointF(30, 41), new System.Drawing.PointF(37, 48), new System.Drawing.PointF(51, 31)]);
        }
        else if (_state is OverlayState.Error or OverlayState.NoSpeech)
        {
            g.DrawLine(whitePen, 41, 29, 41, 43);
            g.DrawEllipse(whitePen, 40, 49, 2, 2);
        }
        else
        {
            using var white = new System.Drawing.SolidBrush(System.Drawing.Color.White);
            g.FillRoundedRectangle(white, new System.Drawing.RectangleF(37, 27, 8, 16), 4);
            g.DrawArc(whitePen, 32, 31, 18, 18, 0, 180);
            g.DrawLine(whitePen, 41, 49, 41, 54);
        }
    }

    private void DrawActivity(System.Drawing.Graphics g, System.Drawing.Color accent)
    {
        using var brush = new System.Drawing.SolidBrush(accent);
        const int count = 9;
        for (var i = 0; i < count; i++)
        {
            var phase = (_frame * 0.52) + (i * 0.8);
            var height = _state == OverlayState.Listening ? 5 + Math.Abs(Math.Sin(phase)) * 18 : 5 + Math.Abs(Math.Sin(phase * 0.7)) * 8;
            var x = 278 + i * 7;
            g.FillRoundedRectangle(brush, new System.Drawing.RectangleF(x, 41 - (float)height / 2, 3, (float)height), 1.5f);
        }
    }

    private static System.Drawing.Drawing2D.GraphicsPath RoundedRectangle(System.Drawing.Rectangle rectangle, int radius)
    {
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _animationTimer.Stop();
            _animationTimer.Dispose();
            Region?.Dispose();
        }
        base.Dispose(disposing);
    }
}

internal sealed record CaptureResult(string WavPath, string DeviceName, long FrameBytes, double Peak, TimeSpan Duration);

internal sealed class AudioRecorder : IAsyncDisposable
{
    private readonly AppConfig _config;
    private WasapiCapture? _capture;
    private WaveFileWriter? _writer;
    private TaskCompletionSource<bool>? _stopped;
    private Stopwatch? _elapsed;
    private long _frameBytes;
    private double _peak;
    private string _path = "";
    private string _deviceName = "";

    public AudioRecorder(AppConfig config, AppPaths paths) => _config = config;

    public void Start(string outputPath)
    {
        var device = DeviceCatalog.Resolve(_config.InputDevice);
        _deviceName = device.FriendlyName;
        _capture = new WasapiCapture(device);
        _writer = new WaveFileWriter(outputPath, _capture.WaveFormat);
        _path = outputPath;
        _stopped = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _capture.DataAvailable += OnData;
        _capture.RecordingStopped += (_, e) =>
        {
            if (e.Exception is not null) _stopped.TrySetException(e.Exception);
            else _stopped.TrySetResult(true);
        };
        _elapsed = Stopwatch.StartNew();
        _capture.StartRecording();
        Log.Info($"WASAPI capture started: {_deviceName}; format={_capture.WaveFormat}");
    }

    private void OnData(object? sender, WaveInEventArgs e)
    {
        _writer?.Write(e.Buffer, 0, e.BytesRecorded);
        Interlocked.Add(ref _frameBytes, e.BytesRecorded);
        _peak = Math.Max(_peak, MeasurePeak(e.Buffer, e.BytesRecorded, _capture!.WaveFormat));
    }

    public async Task<CaptureResult> StopAsync()
    {
        if (_capture is null || _stopped is null || _elapsed is null) throw new InvalidOperationException("Recorder was not started.");
        _capture.StopRecording();
        await _stopped.Task.WaitAsync(TimeSpan.FromSeconds(10));
        _elapsed.Stop();
        _writer?.Dispose();
        _writer = null;
        if (_frameBytes == 0) DeviceCatalog.MarkFailed(_config.InputDevice);
        return new CaptureResult(_path, _deviceName, _frameBytes, _peak, _elapsed.Elapsed);
    }

    private static double MeasurePeak(byte[] data, int count, WaveFormat format)
    {
        double peak = 0;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
        {
            for (var i = 0; i + 3 < count; i += 4)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToSingle(data, i)));
        }
        else if (format.BitsPerSample == 16)
        {
            for (var i = 0; i + 1 < count; i += 2)
                peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(data, i) / 32768d));
        }
        return Math.Min(1, peak);
    }

    public ValueTask DisposeAsync()
    {
        try { if (_capture?.CaptureState == CaptureState.Capturing) _capture.StopRecording(); } catch { }
        _writer?.Dispose();
        _capture?.Dispose();
        return ValueTask.CompletedTask;
    }
}

internal static class DeviceCatalog
{
    private static readonly ConcurrentDictionary<string, byte> FailedDevices = new(StringComparer.OrdinalIgnoreCase);

    public static MMDevice Resolve(string configured)
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).ToList();
        if (devices.Count == 0) throw new InvalidOperationException("Windows reports no active microphone endpoints.");

        if (!configured.Equals("builtin", StringComparison.OrdinalIgnoreCase))
        {
            var exact = FailedDevices.ContainsKey(configured) ? null : devices.FirstOrDefault(d => d.ID.Equals(configured, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return exact;
            Log.Info($"Configured INPUT_DEVICE is missing or previously returned zero frames; falling back to the built-in microphone heuristic: {configured}");
        }

        static bool Wireless(MMDevice d) => Regex.IsMatch(d.FriendlyName, "bluetooth|airpods|hands[- ]?free|headset", RegexOptions.IgnoreCase);
        static bool BuiltIn(MMDevice d) => Regex.IsMatch(d.FriendlyName, "microphone array|internal|built[- ]?in|realtek|intel", RegexOptions.IgnoreCase);
        return devices.OrderBy(d => Wireless(d) ? 2 : BuiltIn(d) ? 0 : 1).First();
    }

    public static void MarkFailed(string configured)
    {
        if (!configured.Equals("builtin", StringComparison.OrdinalIgnoreCase)) FailedDevices.TryAdd(configured, 0);
    }

    public static void Print()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).ToList();
        MMDevice? selected = null;
        try { selected = Resolve("builtin"); } catch { }
        foreach (var device in devices)
        {
            var mark = device.ID == selected?.ID ? "*" : " ";
            Console.WriteLine($"{mark} {device.FriendlyName}\n  {device.ID}");
        }
        Console.WriteLine("* selected by INPUT_DEVICE=builtin");
    }
}

internal sealed class WhisperTranscriber
{
    private readonly AppConfig _config;
    private readonly AppPaths _paths;

    public WhisperTranscriber(AppConfig config, AppPaths paths)
    {
        _config = config;
        _paths = paths;
    }

    public async Task<string> TranscribeAsync(string inputWav, CancellationToken cancellationToken)
    {
        RequireFile(_config.WhisperCli, "whisper-cli");
        RequireFile(_config.WhisperModel, "Whisper model");
        RequireFile(_config.VadModel, "Silero VAD model");
        RequireFile(inputWav, "input WAV");

        var normalized = Path.Combine(_paths.Recordings, Path.GetFileNameWithoutExtension(inputWav) + "-16k.wav");
        await NormalizeAsync(inputWav, normalized, cancellationToken);
        var outputBase = Path.Combine(_paths.Recordings, Path.GetFileNameWithoutExtension(normalized) + "-transcript");
        var args = new List<string>
        {
            "-m", _config.WhisperModel,
            "-f", normalized,
            "--vad", "-vm", _config.VadModel,
            "-bs", "5", "-et", "2.8", "-mc", "128",
            "-l", _config.WhisperLanguage,
            "--prompt", _config.WhisperPrompt,
            "-otxt", "-of", outputBase
        };
        if (_config.WhisperThreads > 0) args.AddRange(["-t", _config.WhisperThreads.ToString(CultureInfo.InvariantCulture)]);
        // Whisper mode: lower the VAD threshold so soft/quiet speech is not gated out.
        if (_config.WhisperMode) args.AddRange(["-vt", "0.15"]);

        Log.Info($"Starting whisper decode with VAD, beam=5, entropy=2.8, max-context=128{(_config.WhisperMode ? ", whisper-mode" : "")}");
        await ProcessRunner.RunAsync(_config.WhisperCli, args, TimeSpan.FromSeconds(_config.WhisperTimeoutSeconds), cancellationToken);
        var transcriptFile = outputBase + ".txt";
        if (!File.Exists(transcriptFile)) throw new InvalidOperationException("whisper-cli completed without producing a transcript file.");
        return await File.ReadAllTextAsync(transcriptFile, cancellationToken);
    }

    private async Task NormalizeAsync(string input, string output, CancellationToken cancellationToken)
    {
        if (_config.PreprocessAudio)
        {
            try
            {
                await ProcessRunner.RunAsync(_config.FfmpegPath,
                    ["-hide_banner", "-loglevel", "error", "-y", "-i", input, "-af", "afftdn=nf=-25,dynaudnorm=f=150:g=15", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", output],
                    TimeSpan.FromMinutes(2), cancellationToken);
                return;
            }
            catch (Exception ex)
            {
                Log.Info($"ffmpeg preprocessing unavailable; using Media Foundation resampling: {ex.Message}");
            }
        }

        await Task.Run(() =>
        {
            using var reader = new WaveFileReader(input);
            using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16000, 16, 1)) { ResamplerQuality = 60 };
            WaveFileWriter.CreateWaveFile(output, resampler);
        }, cancellationToken);
    }

    private static void RequireFile(string path, string label)
    {
        if (!File.Exists(path)) throw new FileNotFoundException($"{label} not found. Run setup.ps1 or update config: {path}", path);
    }
}

internal static class ProcessRunner
{
    public static async Task RunAsync(string file, IEnumerable<string> arguments, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var start = new ProcessStartInfo(file) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };
        if (!process.Start()) throw new InvalidOperationException($"Could not start {file}");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        using var watchdog = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        watchdog.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(watchdog.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            throw new TimeoutException($"{Path.GetFileName(file)} exceeded its {timeout.TotalSeconds:F0}-second watchdog and was terminated.");
        }
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{Path.GetFileName(file)} exited with code {process.ExitCode}: {stderr.ToString().Trim()}");
        if (stderr.Length > 0) Log.Info($"{Path.GetFileName(file)}: {stderr.ToString().Trim()}");
    }
}

internal static class TextFormatter
{
    public static string Format(string input, string glossary)
    {
        if (string.IsNullOrWhiteSpace(input)) return "";
        var text = input.Replace("\r\n", "\n").Replace('\r', '\n').Trim();
        text = Regex.Replace(text, @"(?i)\b(?:um+|uh+)(?!\s+huh\b)\b[,.]?\s*", "");
        text = CollapseRepetitions(text);
        text = SpokenLayout(text);
        text = ApplyGlossary(text, glossary);
        text = Regex.Replace(text, @"[ \t]+([,.;:!?])", "$1");
        text = Regex.Replace(text, @"[ \t]{2,}", " ");
        text = Regex.Replace(text, @" *\n *", "\n");
        text = Regex.Replace(text, @"\n{3,}", "\n\n");
        return text.Trim();
    }

    private static string CollapseRepetitions(string text)
    {
        text = Regex.Replace(text, @"(?ix)\b(?<p>[\p{L}\p{N}'-]+)(?:[\s,]+\k<p>){5,}\b", "${p}");
        text = Regex.Replace(text, @"(?ix)\b(?<p>[\p{L}\p{N}'-]+\s+[\p{L}\p{N}'-]+)(?:[\s,]+\k<p>){4,}\b", "${p}");
        for (var words = 8; words >= 3; words--)
        {
            var pattern = $@"(?ix)\b(?<p>(?:[\p{{L}}\p{{N}}'-]+\s+){{{words - 1}}}[\p{{L}}\p{{N}}'-]+)(?:[\s,]+\k<p>){{3,}}\b";
            text = Regex.Replace(text, pattern, "${p}");
        }
        return text;
    }

    private static string SpokenLayout(string text)
    {
        // Require either a clause boundary before the command or punctuation after it.
        // This avoids changing ordinary phrases such as "add a dash of salt".
        const string left = @"(?:(?<=^)|(?<=[.!?;:,]))[ \t]*";
        text = Regex.Replace(text, left + @"(?i:new paragraph)\b[,:]?[ \t]*", "\n\n");
        text = Regex.Replace(text, left + @"(?i:new line)\b[,:]?[ \t]*", "\n");
        text = Regex.Replace(text, left + @"(?i:bullet)\b[,:]?[ \t]+", "\n- ");
        text = Regex.Replace(text, left + @"(?i:dash)\b(?![ \t]+(?:of|to|from|between|against|with)\b)[,:]?[ \t]+", "\n- ");
        return text;
    }

    private static string ApplyGlossary(string text, string glossary)
    {
        foreach (var item in glossary.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var arrow = item.IndexOf("=>", StringComparison.Ordinal);
            if (arrow <= 0) continue;
            try
            {
                text = Regex.Replace(text, item[..arrow], item[(arrow + 2)..], RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            }
            catch (ArgumentException ex) { Log.Error($"Skipping invalid glossary regex: {item[..arrow]}", ex); }
        }
        return text;
    }
}

internal static class ClipboardPaster
{
    public static async Task PasteAndRestoreAsync(string text)
    {
        var oldClipboard = SnapshotClipboard();
        Clipboard.SetText(text, TextDataFormat.UnicodeText);
        var ours = NativeMethods.GetClipboardSequenceNumber();
        NativeMethods.SendCtrlV();
        await Task.Delay(300);
        if (NativeMethods.GetClipboardSequenceNumber() != ours)
        {
            Log.Info("Clipboard changed during paste; preserving the user's newer clipboard contents");
            return;
        }
        if (oldClipboard is not null) Clipboard.SetDataObject(oldClipboard, true);
        else Clipboard.Clear();
    }

    private static DataObject? SnapshotClipboard()
    {
        IDataObject? source;
        try { source = Clipboard.GetDataObject(); }
        catch { return null; }
        if (source is null) return null;
        var snapshot = new DataObject();
        foreach (var format in source.GetFormats())
        {
            try
            {
                var data = source.GetData(format, autoConvert: false);
                if (data is not null) snapshot.SetData(format, autoConvert: false, data);
            }
            catch { }
        }
        return snapshot;
    }
}

internal sealed class InputHooks : IDisposable
{
    private const int WhKeyboardLl = 13;
    private const int WhMouseLl = 14;
    private const int WmKeyDown = 0x0100;
    private const int WmKeyUp = 0x0101;
    private const int WmSysKeyDown = 0x0104;
    private const int WmSysKeyUp = 0x0105;
    private const int LlkhfInjected = 0x10;
    private const uint VkEscape = 0x1B;
    private readonly uint _target;
    private readonly Action _onTap;
    private readonly Func<bool> _isRecording;
    private readonly Action _onEscape;
    private readonly NativeMethods.HookProc _keyboardProc;
    private readonly NativeMethods.HookProc _mouseProc;
    private nint _keyboardHook;
    private nint _mouseHook;
    private bool _candidate;

    public InputHooks(string hotkey, Action onTap, Func<bool> isRecording, Action onEscape)
    {
        _target = ParseHotkey(hotkey);
        _onTap = onTap;
        _isRecording = isRecording;
        _onEscape = onEscape;
        _keyboardProc = KeyboardCallback;
        _mouseProc = MouseCallback;
    }

    public void Install()
    {
        _keyboardHook = NativeMethods.SetWindowsHookEx(WhKeyboardLl, _keyboardProc, nint.Zero, 0);
        _mouseHook = NativeMethods.SetWindowsHookEx(WhMouseLl, _mouseProc, nint.Zero, 0);
        if (_keyboardHook == 0 || _mouseHook == 0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not install input hooks");
    }

    private nint KeyboardCallback(int code, nint wParam, nint lParam)
    {
        if (code < 0) return NativeMethods.CallNextHookEx(nint.Zero, code, wParam, lParam);
        var data = Marshal.PtrToStructure<NativeMethods.KeyboardHookData>(lParam);
        if ((data.flags & LlkhfInjected) != 0) return NativeMethods.CallNextHookEx(nint.Zero, code, wParam, lParam);
        var message = (int)wParam;
        var down = message is WmKeyDown or WmSysKeyDown;
        var up = message is WmKeyUp or WmSysKeyUp;
        // Escape cancels an active recording outright. Only swallowed while actually
        // recording, so Escape behaves normally for every other app the rest of the time.
        if (data.vkCode == VkEscape && down && _isRecording())
        {
            _candidate = false;
            _onEscape();
            return 1;
        }
        if (data.vkCode == _target)
        {
            if (down && !_candidate)
            {
                _candidate = !OtherModifierIsDown(_target) && !SecureFieldGuard.IsPasswordFocused();
            }
            else if (up)
            {
                var fire = _candidate;
                _candidate = false;
                if (fire) _onTap();
            }
            // Right Win must be swallowed or Windows opens Start. Other keys retain normal behavior.
            if (_target == 0x5C) return 1;
        }
        else if (down)
        {
            _candidate = false;
        }
        return NativeMethods.CallNextHookEx(nint.Zero, code, wParam, lParam);
    }

    private nint MouseCallback(int code, nint wParam, nint lParam)
    {
        const int wmMouseMove = 0x0200;
        if (code >= 0 && _candidate && (int)wParam != wmMouseMove) _candidate = false;
        return NativeMethods.CallNextHookEx(nint.Zero, code, wParam, lParam);
    }

    private static bool OtherModifierIsDown(uint target)
    {
        uint[] modifiers = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C];
        return modifiers.Any(vk => vk != target && (NativeMethods.GetAsyncKeyState((int)vk) & 0x8000) != 0);
    }

    private static uint ParseHotkey(string value)
    {
        var names = new Dictionary<string, uint>(StringComparer.OrdinalIgnoreCase)
        {
            ["RightCtrl"] = 0xA3, ["RightControl"] = 0xA3, ["RightAlt"] = 0xA5, ["RightWin"] = 0x5C,
            ["F13"] = 0x7C, ["F14"] = 0x7D, ["F15"] = 0x7E, ["F16"] = 0x7F, ["F17"] = 0x80, ["F18"] = 0x81,
            ["F19"] = 0x82, ["F20"] = 0x83, ["F21"] = 0x84, ["F22"] = 0x85, ["F23"] = 0x86, ["F24"] = 0x87
        };
        return names.TryGetValue(value, out var key) ? key : throw new InvalidOperationException($"Unsupported HOTKEY: {value}");
    }

    public void Dispose()
    {
        if (_keyboardHook != 0) NativeMethods.UnhookWindowsHookEx(_keyboardHook);
        if (_mouseHook != 0) NativeMethods.UnhookWindowsHookEx(_mouseHook);
    }
}

internal static class SecureFieldGuard
{
    public static bool IsPasswordFocused()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null) return false;
            return (bool)focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty, ignoreDefaultValue: true);
        }
        catch (Exception ex)
        {
            Log.Info($"Password-field check unavailable: {ex.Message}");
            return false;
        }
    }
}

internal sealed class IpcServer : IDisposable
{
    private const string PipeName = "ptt-dictate-control";
    private readonly Func<string, Task<string>> _handler;
    private readonly CancellationTokenSource _shutdown = new();
    private Task? _loop;

    public IpcServer(Func<string, Task<string>> handler) => _handler = handler;
    public void Start() => _loop = Task.Run(LoopAsync);

    private async Task LoopAsync()
    {
        while (!_shutdown.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await pipe.WaitForConnectionAsync(_shutdown.Token);
                using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
                await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
                var command = await reader.ReadLineAsync(_shutdown.Token) ?? "";
                await writer.WriteLineAsync(await _handler(command));
            }
            catch (OperationCanceledException) when (_shutdown.IsCancellationRequested) { }
            catch (Exception ex) { Log.Error("IPC server error", ex); }
        }
    }

    public void Dispose()
    {
        _shutdown.Cancel();
        try { _loop?.Wait(TimeSpan.FromSeconds(1)); } catch { }
        _shutdown.Dispose();
    }
}

internal static class IpcClient
{
    public static async Task<string> SendAsync(string command, TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        await using var pipe = new NamedPipeClientStream(".", "ptt-dictate-control", PipeDirection.InOut, PipeOptions.Asynchronous);
        try { await pipe.ConnectAsync(cancellation.Token); }
        catch (Exception ex) { return $"error: daemon is not running ({ex.Message})"; }
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        await writer.WriteLineAsync(command);
        return await reader.ReadLineAsync(cancellation.Token) ?? "error: empty response";
    }
}

internal static class SoundCue
{
    private static readonly object Gate = new();

    public static void PlayStart(string path) => Play(path, SoundPattern.Start);
    public static void PlayStop(string path) => Play(path, SoundPattern.Stop);
    public static void PlayDone(string path) => Play(path, SoundPattern.Done);
    public static void PlayError() => Play("", SoundPattern.Error);

    public static Task PlayDemoAsync(string startPath, string stopPath, string donePath) => Task.Run(() =>
    {
        lock (Gate)
        {
            PlayBlocking(startPath, SoundPattern.Start);
            Thread.Sleep(260);
            PlayBlocking(stopPath, SoundPattern.Stop);
            Thread.Sleep(300);
            PlayBlocking(donePath, SoundPattern.Done);
        }
    });

    private static void Play(string path, SoundPattern pattern)
    {
        _ = Task.Run(() =>
        {
            lock (Gate)
            {
                PlayBlocking(path, pattern);
            }
        });
    }

    private static void PlayBlocking(string path, SoundPattern pattern)
    {
        try
        {
            if (!string.IsNullOrWhiteSpace(path) && File.Exists(path))
            {
                using var player = new SoundPlayer(path);
                player.PlaySync();
            }
            else
            {
                using var wave = BuildWave(pattern);
                using var player = new SoundPlayer(wave);
                player.PlaySync();
            }
        }
        catch (Exception ex) { Log.Info($"Could not play {pattern} sound: {ex.Message}"); }
    }

    internal static MemoryStream BuildWave(SoundPattern pattern)
    {
        (double Frequency, int Milliseconds)[] notes = pattern switch
        {
            SoundPattern.Start => [(520, 70), (0, 22), (820, 125)],
            SoundPattern.Stop => [(760, 85), (0, 25), (410, 155)],
            SoundPattern.Done => [(650, 55), (0, 18), (840, 65), (0, 18), (1080, 120)],
            _ => [(280, 130), (0, 25), (190, 210)]
        };
        const int sampleRate = 22050;
        var sampleCount = notes.Sum(note => sampleRate * note.Milliseconds / 1000);
        var stream = new MemoryStream(44 + sampleCount * 2);
        using (var writer = new BinaryWriter(stream, Encoding.ASCII, leaveOpen: true))
        {
            writer.Write(Encoding.ASCII.GetBytes("RIFF"));
            writer.Write(36 + sampleCount * 2);
            writer.Write(Encoding.ASCII.GetBytes("WAVE"));
            writer.Write(Encoding.ASCII.GetBytes("fmt "));
            writer.Write(16);
            writer.Write((short)1);
            writer.Write((short)1);
            writer.Write(sampleRate);
            writer.Write(sampleRate * 2);
            writer.Write((short)2);
            writer.Write((short)16);
            writer.Write(Encoding.ASCII.GetBytes("data"));
            writer.Write(sampleCount * 2);
            foreach (var (frequency, milliseconds) in notes)
            {
                var noteSamples = sampleRate * milliseconds / 1000;
                var fadeSamples = Math.Min(sampleRate / 100, Math.Max(1, noteSamples / 3));
                for (var sample = 0; sample < noteSamples; sample++)
                {
                    var envelope = Math.Min(1d, Math.Min((sample + 1d) / fadeSamples, (noteSamples - sample) / (double)fadeSamples));
                    var value = frequency == 0 ? 0 : Math.Sin(2 * Math.PI * frequency * sample / sampleRate) * 0.24 * envelope;
                    writer.Write((short)(value * short.MaxValue));
                }
            }
        }
        stream.Position = 0;
        return stream;
    }
}

internal enum SoundPattern
{
    Start,
    Stop,
    Done,
    Error
}

internal static class TrayIcons
{
    public static System.Drawing.Icon Create(System.Drawing.Color color)
    {
        using var bitmap = new System.Drawing.Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        graphics.Clear(System.Drawing.Color.Transparent);
        using var background = new System.Drawing.SolidBrush(color);
        using var white = new System.Drawing.SolidBrush(System.Drawing.Color.White);
        using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 2.2f)
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round
        };
        graphics.FillEllipse(background, 1, 1, 30, 30);
        graphics.FillRoundedRectangle(white, new System.Drawing.RectangleF(12, 7, 8, 12), 4);
        graphics.DrawArc(pen, 9, 9, 14, 14, 0, 180);
        graphics.DrawLine(pen, 16, 23, 16, 26);
        graphics.DrawLine(pen, 12, 26, 20, 26);
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = System.Drawing.Icon.FromHandle(handle);
            return (System.Drawing.Icon)temporary.Clone();
        }
        finally
        {
            NativeMethods.DestroyIcon(handle);
        }
    }

    internal static void FillRoundedRectangle(this System.Drawing.Graphics graphics, System.Drawing.Brush brush, System.Drawing.RectangleF rectangle, float radius)
    {
        using var path = new System.Drawing.Drawing2D.GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
        path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        graphics.FillPath(brush, path);
    }
}

internal static class SelfTests
{
    public static int Run()
    {
        var failures = new List<string>();
        Check("fillers", "I think this works.", TextFormatter.Format("Um, I think uh this works.", ""), failures);
        Check("uh huh preserved", "Uh huh, that works.", TextFormatter.Format("Uh huh, that works.", ""), failures);
        Check("one-word loop", "hello world", TextFormatter.Format("hello hello hello hello hello hello world", ""), failures);
        Check("two-word loop", "thank you.", TextFormatter.Format("thank you thank you thank you thank you thank you.", ""), failures);
        Check("dash phrase preserved", "Add a dash of salt.", TextFormatter.Format("Add a dash of salt.", ""), failures);
        Check("layout", "First.\n\nSecond.", TextFormatter.Format("First. new paragraph Second.", ""), failures);
        Check("bullet", "Things:\n- apples", TextFormatter.Format("Things: bullet apples", ""), failures);
        Check("glossary", "Use Next.js and Codex.", TextFormatter.Format("Use next js and codex.", @"\bnext\s+js\b=>Next.js;\bcodex\b=>Codex"), failures);
        Check("prompt cap", "165", Regex.Matches(PromptLimiter.Limit(string.Join(' ', Enumerable.Repeat("x", 300))), @"\S+").Count.ToString(), failures);
        Check("Win64 INPUT size", "40", NativeMethods.InputStructureSize.ToString(CultureInfo.InvariantCulture), failures);
        using (var start = SoundCue.BuildWave(SoundPattern.Start))
        using (var stop = SoundCue.BuildWave(SoundPattern.Stop))
        using (var done = SoundCue.BuildWave(SoundPattern.Done))
        {
            Check("sound WAV header", "RIFF", Encoding.ASCII.GetString(start.ToArray(), 0, 4), failures);
            Check("distinct sound patterns", "3", new HashSet<long> { start.Length, stop.Length, done.Length }.Count.ToString(CultureInfo.InvariantCulture), failures);
        }
        Check("successful recording cleanup", "4", TestRecordingCleanup().ToString(CultureInfo.InvariantCulture), failures);
        if (failures.Count == 0)
        {
            Console.WriteLine("13 self-tests passed.");
            return 0;
        }
        foreach (var failure in failures) Console.Error.WriteLine(failure);
        return 1;
    }

    private static void Check(string name, string expected, string actual, List<string> failures)
    {
        if (expected != actual) failures.Add($"FAIL {name}: expected [{expected}], got [{actual}]");
    }

    private static int TestRecordingCleanup()
    {
        var directory = Path.Combine(Path.GetTempPath(), "ptt-dictate-cleanup-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var raw = Path.Combine(directory, "dictation-test-raw.wav");
            File.WriteAllText(raw, "raw");
            File.WriteAllText(Path.Combine(directory, "dictation-test-raw-16k.wav"), "normalized");
            File.WriteAllText(Path.Combine(directory, "dictation-test-raw-16k-transcript.txt"), "text");
            var unrelated = Path.Combine(directory, "keep-me.wav");
            File.WriteAllText(unrelated, "keep");
            var deleted = RecordingCleanup.DeleteSuccessful(raw);
            return deleted == 3 && File.Exists(unrelated) ? 4 : deleted;
        }
        finally
        {
            try { Directory.Delete(directory, recursive: true); } catch { }
        }
    }
}

internal static class PasteIntegrationTest
{
    public static int Run()
    {
        const string marker = "ptt-dictate paste integration test";
        var succeeded = false;
        using var form = new Form
        {
            Text = "ptt-dictate paste test",
            Width = 520,
            Height = 120,
            StartPosition = FormStartPosition.CenterScreen,
            FormBorderStyle = FormBorderStyle.FixedToolWindow,
            ShowInTaskbar = false,
            TopMost = true
        };
        using var textBox = new TextBox { Dock = DockStyle.Fill, Multiline = true };
        form.Controls.Add(textBox);
        form.Shown += async (_, _) =>
        {
            form.Activate();
            form.BringToFront();
            NativeMethods.SetForegroundWindow(form.Handle);
            textBox.Focus();
            textBox.Select();
            await Task.Delay(300);
            try
            {
                Log.Info($"Paste test focus: containsFocus={textBox.ContainsFocus}, foreground={NativeMethods.GetForegroundWindow()}, form={form.Handle}");
                await ClipboardPaster.PasteAndRestoreAsync(marker);
                await Task.Delay(300);
                succeeded = textBox.Text == marker;
                Log.Info($"Paste test result: succeeded={succeeded}, length={textBox.Text.Length}");
            }
            catch (Exception ex)
            {
                Log.Error("Paste integration test failed", ex);
            }
            form.Close();
        };
        form.ShowDialog();
        Console.WriteLine(succeeded ? "Paste integration test passed." : "Paste integration test failed.");
        return succeeded ? 0 : 1;
    }
}

internal static class Log
{
    private static readonly object Gate = new();
    private static string _path = Path.Combine(Path.GetTempPath(), "ptt-dictate.log");
    public static void Initialize(string path)
    {
        _path = path;
        try
        {
            if (!File.Exists(path) || new FileInfo(path).Length < 5 * 1024 * 1024) return;
            var previous = path + ".1";
            if (File.Exists(previous)) File.Delete(previous);
            File.Move(path, previous);
        }
        catch { }
    }
    public static void Info(string message) => Write("INFO", message);
    public static void Error(string message, Exception ex) => Write("ERROR", $"{message}: {ex}");
    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.AppendAllText(_path, $"{DateTimeOffset.Now:O} [{level}] {message}{Environment.NewLine}");
        }
    }
}

internal static class NativeMethods
{
    internal delegate nint HookProc(int code, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyboardHookData
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public nuint dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint type;
        public InputUnion union;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KeyboardInput keyboard;
        [FieldOffset(0)] public MouseInput mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort virtualKey;
        public ushort scanCode;
        public uint flags;
        public uint time;
        public nuint extraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint flags;
        public uint time;
        public nuint extraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint SetWindowsHookEx(int hookId, HookProc callback, nint module, uint threadId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool UnhookWindowsHookEx(nint hook);
    [DllImport("user32.dll")]
    internal static extern nint CallNextHookEx(nint hook, int code, nint wParam, nint lParam);
    [DllImport("user32.dll")]
    internal static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")]
    internal static extern nint GetForegroundWindow();
    [DllImport("user32.dll")]
    internal static extern uint GetWindowThreadProcessId(nint window, out uint processId);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetWindowPos(nint window, nint insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    internal static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool DestroyIcon(nint icon);

    internal static int InputStructureSize => Marshal.SizeOf<Input>();

    internal static void SendCtrlV()
    {
        const ushort ctrl = 0x11;
        const ushort v = 0x56;
        const uint keyUp = 0x0002;
        Input[] inputs =
        [
            new() { type = 1, union = new InputUnion { keyboard = new KeyboardInput { virtualKey = ctrl } } },
            new() { type = 1, union = new InputUnion { keyboard = new KeyboardInput { virtualKey = v } } },
            new() { type = 1, union = new InputUnion { keyboard = new KeyboardInput { virtualKey = v, flags = keyUp } } },
            new() { type = 1, union = new InputUnion { keyboard = new KeyboardInput { virtualKey = ctrl, flags = keyUp } } }
        ];
        if (SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>()) != inputs.Length)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SendInput could not synthesize Ctrl+V");
    }
}
