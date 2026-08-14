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

import math
import os
import struct
import time

import httpx
from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse
from starlette.formparsers import MultiPartParser

LICENSE_URL = os.environ.get("LICENSE_URL", "https://nesso.tech/api/license")
DECODER = "http://127.0.0.1:8977/inference"

# 32 MB is ~16 minutes of 16 kHz mono s16. The desktop client cuts a new chunk
# every 30 seconds, so a real request is about 1 MB and nothing legitimate comes
# close to this. Deliberately far below the old 120 MB, because every accepted
# byte now has to fit in RAM (see the spool override directly below).
MAX_BYTES = int(os.environ.get("MAX_BYTES", 32 * 1024 * 1024))

# PRIVACY-CRITICAL. Starlette backs UploadFile with a SpooledTemporaryFile whose
# default max_size is 1 MB, and 1 MB of 16 kHz mono s16 is 32.8 seconds. Past
# that it silently rolls over and writes the customer's audio to the container's
# disk, which makes the site's "nothing is stored" claim false for any dictation
# longer than about half a minute. gate.py itself never opens a file, so this is
# invisible in our own code. Raising the spool ceiling above MAX_BYTES keeps
# every accepted upload in memory for its whole life.
MultiPartParser.spool_max_size = MAX_BYTES + (1024 * 1024)

# Whisper pads every input to a fixed 30-second encoder window, so a 4-second
# dictation spends most of its compute encoding silence. audio_ctx shrinks that
# window. MEASURED on this exact model (large-v3-turbo q5_0) with VAD on:
#   ac=0 (full)  1.64s / 1.67s   correct
#   ac=320       2.06s / 3.10s   COLLAPSED into a repetition loop
#   ac=384       1.32s / 3.84s   COLLAPSED on one clip
#   ac=448       0.65s / 1.44s   correct
#   ac=512       0.69s / 0.72s   correct  <- floor, 2.4x faster than full
# The widely-cited formula (dur/30*1500 + 128) computes 348 for these clips,
# which is squarely inside the zone where the decoder degenerates. So we floor
# hard at 512 and carry a much larger margin than the formula suggests.
# The failure mode is silent and catastrophic rather than gradual, so
# AUDIO_CTX=0 turns the whole optimization off without a redeploy.
AUDIO_CTX_ON = os.environ.get("AUDIO_CTX", "1") != "0"
AUDIO_CTX_FLOOR = int(os.environ.get("AUDIO_CTX_FLOOR", 512))
AUDIO_CTX_MARGIN = int(os.environ.get("AUDIO_CTX_MARGIN", 256))
AUDIO_CTX_MAX = 1500

app = FastAPI()

# (key, machine, platform) -> (valid, expiry). Keying on the key ALONE let any
# machine ride a cached answer that was granted to a different machine, which
# defeated per-platform seat binding for the length of the window. Positive
# answers cache 60 seconds, not 10 minutes: revocation is the product, and a
# ten-minute window meant "take it away" took ten minutes to mean anything.
_cache: dict[tuple[str, str, str], tuple[bool, float]] = {}
_CACHE_MAX = 5000


def _sweep_cache(now: float) -> None:
    # Unbounded growth here is a slow leak on a long-lived container. Drop the
    # expired entries first, and if that is not enough, drop the oldest.
    if len(_cache) < _CACHE_MAX:
        return
    for k in [k for k, v in _cache.items() if v[1] <= now]:
        _cache.pop(k, None)
    while len(_cache) >= _CACHE_MAX:
        _cache.pop(min(_cache, key=lambda k: _cache[k][1]), None)


async def license_ok(key: str, machine: str, platform: str) -> bool:
    ck = (key, machine, platform)
    hit = _cache.get(ck)
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
    _sweep_cache(now)
    _cache[ck] = (ok, now + (60 if ok else 60))
    return ok


def wav_duration_seconds(audio: bytes) -> float:
    """Duration from the WAV header, falling back to the client's known format.

    Only used to size the encoder window, so an approximate answer is fine and a
    wrong answer is safe: the floor and the cap both bound the result.
    """
    default = len(audio) / 32_000.0  # 16 kHz mono s16 = 32 kB/s
    try:
        if len(audio) < 44 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
            return default
        off = 12
        byte_rate = 0
        while off + 8 <= len(audio):
            cid = audio[off:off + 4]
            size = struct.unpack("<I", audio[off + 4:off + 8])[0]
            body = off + 8
            if cid == b"fmt " and body + 16 <= len(audio):
                byte_rate = struct.unpack("<I", audio[body + 8:body + 12])[0]
            elif cid == b"data":
                if byte_rate > 0:
                    return min(size, len(audio) - body) / float(byte_rate)
                return default
            off = body + size + (size & 1)
        return default
    except (struct.error, ZeroDivisionError, IndexError):
        return default


def audio_ctx_for(duration: float) -> int | None:
    if not AUDIO_CTX_ON:
        return None
    want = int(math.ceil(duration / 30.0 * AUDIO_CTX_MAX)) + AUDIO_CTX_MARGIN
    ctx = max(AUDIO_CTX_FLOOR, min(AUDIO_CTX_MAX, want))
    # At or above the full window there is nothing to save, and sending the max
    # explicitly would only risk diverging from the decoder's own default.
    return None if ctx >= AUDIO_CTX_MAX else ctx


@app.get("/health")
async def health():
    # Health means the DECODER answers, not merely this gate process. The
    # first deploy shipped a decoder that could not start while /health said
    # ok; never let that happen again.
    #
    # The STATUS CODE has to carry it too. Returning 200 with {"decoder": false}
    # is honest to a human reading the body and invisible to every automated
    # health check, which is how a dead decoder could stay dead indefinitely.
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.get("http://127.0.0.1:8977/")
        decoder = r.status_code == 200
    except httpx.HTTPError:
        decoder = False
    body = {
        "ok": decoder,
        "decoder": decoder,
        "model": os.environ.get("MODEL_TAG", "engine-v1"),
    }
    return JSONResponse(body, status_code=200 if decoder else 503)


@app.post("/transcribe")
async def transcribe(
    request: Request,
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
    # A blank machine id used to sail straight past per-platform seat binding on
    # nesso.tech, because the seat check there is wrapped in `if (machine)`.
    mach = machine.strip()
    if not mach:
        raise HTTPException(status_code=400, detail="machine_required")
    if not await license_ok(lic, mach, platform.strip()):
        raise HTTPException(status_code=402, detail="inactive")

    audio = await file.read()
    if not audio:
        raise HTTPException(status_code=400, detail="empty")
    if len(audio) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="too_large")

    # Per-request vad/prompt/language/audio_ctx are the knobs whisper-server
    # honors at request time (VAD threshold is fixed at launch, same as the
    # desktop daemon's resident server).
    data = {"response_format": "json", "vad": "true", "language": language}
    if prompt:
        data["prompt"] = prompt
    ctx = audio_ctx_for(wav_duration_seconds(audio))
    if ctx is not None:
        data["audio_ctx"] = str(ctx)

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


@app.middleware("http")
async def reject_oversized_before_reading(request: Request, call_next):
    # Content-Length is checked before the body is parsed, so an oversized upload
    # is refused at the door instead of after it has been buffered in memory.
    if request.url.path == "/transcribe":
        cl = request.headers.get("content-length")
        if cl and cl.isdigit() and int(cl) > MAX_BYTES + (2 * 1024 * 1024):
            return JSONResponse({"detail": "too_large"}, status_code=413)
    return await call_next(request)
