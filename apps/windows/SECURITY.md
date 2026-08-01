# Security policy

## Reporting a vulnerability

Please do not disclose security vulnerabilities in a public issue. Use GitHub's
private vulnerability reporting feature for this repository instead.

Include the affected version, reproduction steps, impact, and any suggested
mitigation. Reports involving microphone capture, clipboard handling, input
hooks, model downloads, or startup persistence are especially helpful.

## Privacy model

ptt-dictate performs transcription locally with whisper.cpp. Successful audio
and temporary transcript files are deleted after the transcript is loaded into
memory. Failed recordings are retained locally for recovery and can contain
sensitive speech, so users should review the recordings folder periodically.

API keys and model binaries must never be committed. Use the local plain-text
configuration file under `%LOCALAPPDATA%\ptt-dictate` for machine-specific
settings.
