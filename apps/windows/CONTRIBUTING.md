# Contributing

Contributions are welcome. Please keep changes focused and preserve the core
privacy and safety guarantees: local transcription, mandatory VAD, bounded
recording duration, guarded clipboard restoration, and non-activating status UI.

## Development

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1 -BuildOnly
.\ptt.ps1 test
.\ptt.ps1 build
```

Before opening a pull request, verify that the release build succeeds, all
self-tests pass, and no models, recordings, logs, credentials, or generated
artifacts are staged.
