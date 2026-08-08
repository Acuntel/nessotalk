# NessoTalk Engine

The hosted speech-to-text service. Customers never download a model; their app
sends audio here with a license key and gets text back. Access to the engine is
granted and revoked per license in real time, with no offline grace and nothing
to crack client-side.

## Architecture

```
client app ── multipart WAV + license key ──> gate.py (public, $PORT)
                                                │  license check against
                                                │  nesso.tech/api/license
                                                │  (cached 10 min)
                                                ▼
                                        whisper-server (localhost:8977)
                                        nessotalk-engine weights, resident
```

- **Weights live in the private GitHub Release** (`engine-v1` on
  Acuntel/nessotalk): `boot.sh` fetches them at container start using
  `GH_TOKEN`. Rotate or revoke that token and the model is unreachable.
  They are never in the image, never in a public bucket, never on a customer
  machine.
- **Model swaps are fleet-wide**: publish `engine-v2` assets, flip the
  `MODEL_TAG` env, redeploy. No client update.
- **No audio persistence**: the gate holds audio in memory and never logs
  transcript content. This keeps the site's privacy claims literally true.

## Env vars

| var | default | meaning |
| --- | --- | --- |
| `GH_TOKEN` | required | GitHub token that can read the private release |
| `MODEL_REPO` | `Acuntel/nessotalk` | repo holding the release |
| `MODEL_TAG` | `engine-v1` | release tag to serve |
| `LICENSE_URL` | `https://nesso.tech/api/license` | license validator |
| `WHISPER_THREADS` | `8` | decoder threads, match the vCPU count |
| `VAD_THRESHOLD` | `0.15` | fixed at launch, same as the desktop daemon |
| `PORT` | `8080` | set by Railway |

## Deploy (Railway)

```
cd engine
railway up
```

Then set the env vars above on the service. Verify:

```
curl -s https://<service-url>/health
curl -s -X POST https://<service-url>/transcribe \
  -H "x-license-key: <real key>" \
  -F machine=<real IOPlatformUUID> -F platform=mac \
  -F file=@sample16k.wav
```

A bad or revoked key gets 402 before the model is ever touched.

## Serving notes

- CPU serving decodes at roughly 2-4x realtime with the q5 quant. Fine for
  beta; the p95 stop-to-paste number decides when to move to a GPU host
  (RunPod class, roughly $250-350/mo flat). Same container, same contract.
- whisper-server honors per-request `vad`, `prompt`, `language`; the VAD
  threshold is baked at launch (same gotcha as the desktop resident server).
