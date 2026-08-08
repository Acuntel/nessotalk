"""NessoTalk Engine gate.

The only public surface of the hosted engine. Every request must carry a live
license key: access to transcription is granted and revoked in the profiles
table on nesso.tech, and a revoked customer's very next dictation gets a 402.
There is no offline grace here and nothing to patch client-side, because the
capability was never on their machine.

Audio is held in memory, decoded, and discarded. Nothing is written to disk
and no transcript content is ever logged, so the site's privacy copy
("transcribed, then immediately discarded") stays literally true.
"""

import os
import time

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile

LICENSE_URL = os.environ.get("LICENSE_URL", "https://nesso.tech/api/license")
DECODER = "http://127.0.0.1:8977/inference"
MAX_BYTES = 120 * 1024 * 1024  # 45-minute cap at 16 kHz mono s16 is ~86 MB

app = FastAPI()

# key -> (valid, cache_expiry). Positive answers cache 10 minutes so steady
# dictation costs one license lookup per user per window; negative answers
# cache 60 seconds so a just-restored customer is not locked out long.
_cache: dict[str, tuple[bool, float]] = {}


async def license_ok(key: str, machine: str, platform: str) -> bool:
    hit = _cache.get(key)
    now = time.time()
    if hit and hit[1] > now:
        return hit[0]
    # machine/platform are forwarded from the client verbatim: /api/license
    # does per-platform seat binding, and inventing an id here would claim a
    # customer's seat (the field is `machine`, not `machine_id`).
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.post(
                LICENSE_URL,
                json={"key": key, "machine": machine, "platform": platform},
            )
        ok = r.status_code == 200 and bool(r.json().get("valid"))
    except (httpx.HTTPError, ValueError):
        # License server unreachable: fail CLOSED for new keys, but let a
        # recently-validated key ride out the blip via the cache below.
        raise HTTPException(status_code=503, detail="license_check_failed")
    _cache[key] = (ok, now + (600 if ok else 60))
    return ok


@app.get("/health")
async def health():
    # Health means the DECODER answers, not merely this gate process. The
    # first deploy shipped a decoder that could not start while /health said
    # ok; never let that happen again.
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://127.0.0.1:8977/")
        decoder = r.status_code == 200
    except httpx.HTTPError:
        decoder = False
    return {
        "ok": decoder,
        "decoder": decoder,
        "model": os.environ.get("MODEL_TAG", "engine-v1"),
    }


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    machine: str = Form(...),
    platform: str = Form("mac"),
    prompt: str = Form(""),
    language: str = Form("en"),
    key: str = Form(""),
    x_license_key: str = Header(""),
):
    lic = (x_license_key or key).strip()
    if not lic:
        raise HTTPException(status_code=401, detail="license_required")
    if not await license_ok(lic, machine.strip(), platform.strip()):
        raise HTTPException(status_code=402, detail="inactive")

    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="empty")
    if len(audio) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="too_large")

    # Per-request vad/prompt/language are the knobs whisper-server honors at
    # request time (VAD threshold is fixed at launch, same as the desktop
    # daemon's resident server).
    data = {"response_format": "json", "vad": "true", "language": language}
    if prompt:
        data["prompt"] = prompt

    try:
        async with httpx.AsyncClient(timeout=600) as c:
            r = await c.post(
                DECODER,
                data=data,
                files={"file": (file.filename or "audio.wav", audio, "audio/wav")},
            )
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="decoder_down")
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail="decoder")
    text = (r.json().get("text") or "").strip()
    return {"text": text}
