# ptt-dictate for Windows

[![CI](https://github.com/jeremymhayes/ptt-dictate-windows/actions/workflows/ci.yml/badge.svg)](https://github.com/jeremymhayes/ptt-dictate-windows/actions/workflows/ci.yml)

Private, local push-to-talk dictation for Windows. No cloud transcription, no subscription, and no terminal window after installation.

`ptt-dictate` is a local push-to-talk dictation daemon for Windows. Tap **Right Ctrl** to start recording, speak, then tap it again to transcribe with `whisper.cpp`, clean up the transcript, and paste it into the focused app.

After installation it runs silently in the notification area with no terminal window. The tray icon is green when ready, red while recording, and amber while transcribing. Right-click it for status, recording controls, settings, recordings, logs, and About; double-click it to start or stop recording.

A compact Windows-native status pill appears above the taskbar without taking keyboard focus. It shows a live recording timer and waveform while listening, local processing progress while transcribing, and a brief Done, No speech, or Error result.

The Windows port keeps the load-bearing behavior from the macOS brief while using native Windows equivalents:

| macOS brief | Windows implementation |
| --- | --- |
| Swift menu-bar daemon | single-source C#/.NET tray daemon |
| `AVCaptureSession` | WASAPI capture through NAudio |
| Right Command event tap | low-level keyboard and mouse hooks; Right Ctrl by default |
| Accessibility/TCC | normal user process plus Windows password-field and focus guards |
| `NSPasteboard` + `CGEvent` | Win32 clipboard sequence guard + `SendInput(Ctrl+V)` |
| `SIGUSR1` test tap | named-pipe command: `ptt tap` |
| `launchd` KeepAlive | hidden per-user Scheduled Task with restart-on-failure |
| `.app` signing | signed .NET host + managed app DLL; standalone signed-ready `.exe` also built |

## Install

Open PowerShell in this directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
.\ptt.ps1 devices
.\ptt.ps1 miccheck
.\ptt.ps1 install
```

`setup.ps1` installs a private .NET 9 SDK if needed, downloads the latest official Windows x64 `whisper.cpp` release, downloads the large-v3-turbo Q5 and Silero VAD models, builds the application, and creates `%LOCALAPPDATA%\ptt-dictate\config`. The model is large; use `-SkipModel` if you want to supply it yourself. ffmpeg preprocessing is optional because Media Foundation handles the required 16 kHz mono conversion; pass `-InstallFfmpeg` to enable denoise and dynamic normalization.

The build emits both a self-contained `ptt-dictate-standalone.exe` and a runtime-hosted `ptt-dictate.dll`. Control and startup commands use the managed DLL through Microsoft's signed `dotnet.exe`; this works on Windows Application Control configurations that block locally generated unsigned executables. The standalone EXE is ready for Authenticode signing and distribution.

At sign-in, Task Scheduler starts `wscript.exe`, which launches the signed .NET host with its window hidden and waits for the daemon. This keeps the task monitor attached for failure recovery without displaying a console.

The daemon runs at normal user integrity. It intentionally cannot paste into an elevated administrator window; this is Windows UIPI protection, not an app permission bug.

## Control commands

```powershell
.\ptt.ps1 start
.\ptt.ps1 stop
.\ptt.ps1 restart
.\ptt.ps1 status
.\ptt.ps1 log
.\ptt.ps1 build
.\ptt.ps1 miccheck
.\ptt.ps1 devices
.\ptt.ps1 tap
.\ptt.ps1 test
```

Configuration is plain `KEY=VALUE` text at `%LOCALAPPDATA%\ptt-dictate\config` and is read at launch. Restart after editing it. `INPUT_DEVICE=builtin` prefers an active integrated/non-Bluetooth microphone. To pin a specific device, copy its full endpoint ID from `ptt devices`.

For a portable/test install, set `PTT_DICTATE_HOME` before running any command; otherwise `%LOCALAPPDATA%\ptt-dictate` is used.

## Safety and behavior

- Silero VAD is mandatory for every decode. Beam size 5, entropy threshold 2.8, max context 128, and an initial prompt capped below roughly 220 tokens are always applied.
- Recordings auto-stop after 45 minutes by default. The whisper child process has a separate watchdog and is killed as a process tree on timeout.
- A bare-modifier tap is vetoed by any other key, mouse click/scroll, pre-held modifier, or focused password field.
- The app snapshots the clipboard, pastes, and restores the snapshot only if the clipboard sequence number proves nothing else changed.
- After transcription finishes, the result pastes into the application that is currently in the foreground. Keep the intended text box focused while the local decode runs.
- Successful dictations delete their raw WAV, normalized WAV, and temporary transcript immediately after the transcript is loaded into memory. Failed recordings stay in `%LOCALAPPDATA%\ptt-dictate\recordings` for recovery, and completed leftovers from a crash are removed at the next startup. No audio or transcript is sent to a cloud service.
- Start, stop, and completion use distinct built-in rising, falling, and success chimes. `START_SOUND`, `STOP_SOUND`, and `DONE_SOUND` can point to custom WAV files to override them.

## Test hooks

```powershell
Get-Content sample.wav -ErrorAction Stop | Out-Null
dotnet "$env:LOCALAPPDATA\ptt-dictate\ptt-dictate.dll" --transcribe-file .\sample.wav
'um use next js new paragraph codex' | dotnet "$env:LOCALAPPDATA\ptt-dictate\ptt-dictate.dll" --format-stdin
.\ptt.ps1 tap
```

## Acceptance checks

1. `ptt miccheck` captures nonzero frames from the intended microphone, logs a nonzero peak, and transcribes your speech.
2. Tap Right Ctrl, say a sentence containing “um” and a glossary name, tap again, and verify clean text is pasted.
3. Start in one app, switch apps while recording, stop, and verify the stop-time app receives the paste.
4. Sleep and resume Windows, then perform another dictation without restarting. WASAPI capture is created fresh for every recording.
5. Run `ptt build`, restart, and verify the daemon works without a permission re-grant. Windows does not key mic/input-hook access to an ad-hoc code signature.
6. Temporarily set `MAX_RECORD_MINUTES=1`, walk away, and verify the log records `automatic safety cap`.

## Optional phases

The config reserves server, rolling-decode, and LLM-polish settings, but those optional phases are disabled in this first reliable build. Raw local dictation never depends on a server or API. If LLM polish is added later, it must retain the original brief's length, timeout, focus, and raw-transcript trust gates.
