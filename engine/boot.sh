#!/usr/bin/env bash
set -euo pipefail

MODEL_DIR="${MODEL_DIR:-/models}"
MODEL_REPO="${MODEL_REPO:-Acuntel/nessotalk}"
MODEL_TAG="${MODEL_TAG:-engine-v1}"
mkdir -p "$MODEL_DIR"

# Pull the engine weights from the private GitHub Release. GH_TOKEN is the only
# credential that can reach them, which makes it the give/take-away lever for
# the model itself: rotate or revoke the token and nothing can fetch these
# weights again. Bumping MODEL_TAG (engine-v1 -> engine-v2) swaps the whole
# fleet to a new model with no client update.
fetch() {
  local name="$1"
  [ -s "$MODEL_DIR/$name" ] && return 0
  echo "engine: fetching $name from $MODEL_REPO@$MODEL_TAG"
  local asset_id
  asset_id=$(curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$MODEL_REPO/releases/tags/$MODEL_TAG" \
    | python3 -c "import sys, json; print([a['id'] for a in json.load(sys.stdin)['assets'] if a['name'] == '$name'][0])")
  curl -fsSL -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/octet-stream" \
    -o "$MODEL_DIR/$name.part" \
    "https://api.github.com/repos/$MODEL_REPO/releases/assets/$asset_id"
  mv "$MODEL_DIR/$name.part" "$MODEL_DIR/$name"
}
fetch "nessotalk-engine-${MODEL_TAG#engine-}-q5_0.bin"
fetch "nessotalk-vad-v1.bin"

# Parakeet weights are public (CC-BY-4.0) so they need no token, but they are
# still only ever reachable through the licence gate: the decoder binds to
# localhost and gate.py is the sole public surface. Attribution lives on the
# site's acknowledgements page.
PARAKEET_MODEL="${PARAKEET_MODEL:-tdt-0.6b-v3-q8_0.gguf}"
if [ ! -s "$MODEL_DIR/$PARAKEET_MODEL" ]; then
  echo "engine: fetching $PARAKEET_MODEL"
  curl -fsSL -o "$MODEL_DIR/$PARAKEET_MODEL.part" \
    "https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/$PARAKEET_MODEL" \
    && mv "$MODEL_DIR/$PARAKEET_MODEL.part" "$MODEL_DIR/$PARAKEET_MODEL" \
    || { rm -f "$MODEL_DIR/$PARAKEET_MODEL.part"; echo "engine: parakeet fetch FAILED, whisper will serve everything" >&2; }
fi

# Resident decoder on localhost only. The gate below is the only public
# surface, so an unlicensed request never reaches the model at all.
#
# Decode flags MIRROR the desktop's proven resident-server launch args
# EXACTLY (beam 5 + best-of 5, entropy fallback 2.8, -mc 128, prompt carry).
# The first deploy omitted them and shipped noticeably worse transcripts —
# this block must stay in lockstep with `ptt server sync`. Do not add flags
# the local plist does not carry: an unaccepted launch flag kills the server.
start_decoder() {
  whisper-server \
    -m "$MODEL_DIR/nessotalk-engine-${MODEL_TAG#engine-}-q5_0.bin" \
    --host 127.0.0.1 --port 8977 -t "${WHISPER_THREADS:-8}" \
    -nt -l "${ENGINE_LANGUAGE:-en}" \
    -mc 128 -et 2.8 -bs 5 -bo 5 \
    --carry-initial-prompt \
    --vad -vm "$MODEL_DIR/nessotalk-vad-v1.bin" -vt "${VAD_THRESHOLD:-0.15}" &
  DECODER_PID=$!
}

start_decoder

# Parakeet is the primary decoder for the languages it covers. If it cannot
# start we do NOT fail the container: gate.py falls back to whisper for every
# request, which is exactly the behaviour we had before it existed.
PARAKEET_PID=""
start_parakeet() {
  [ -s "$MODEL_DIR/$PARAKEET_MODEL" ] || return 0
  parakeet-server \
    --model "$MODEL_DIR/$PARAKEET_MODEL" \
    --host 127.0.0.1 --port 8978 \
    --threads "${PARAKEET_THREADS:-${WHISPER_THREADS:-8}}" &
  PARAKEET_PID=$!
}
start_parakeet

for _ in $(seq 1 180); do
  curl -fsS -o /dev/null "http://127.0.0.1:8977/" 2>/dev/null && break
  sleep 1
done

# If the decoder never came up, exit non-zero so the platform restarts the whole
# container. Staying alive here would serve a gate that can only ever 502.
if ! curl -fsS -o /dev/null "http://127.0.0.1:8977/" 2>/dev/null; then
  echo "engine: decoder never answered after 180s, exiting so the platform restarts us" >&2
  exit 1
fi

# Supervise it. Nothing used to restart whisper-server if it died mid-flight:
# the gate stayed up as PID 1, so the container looked healthy while every
# transcription returned 502 forever. /health now reports 503 in that state as
# well, but a supervisor means most deaths are repaired before anyone notices.
supervise_decoder() {
  while true; do
    sleep 15
    if ! kill -0 "$DECODER_PID" 2>/dev/null; then
      echo "engine: decoder process died, restarting it" >&2
      start_decoder
      continue
    fi
    if [ -n "$PARAKEET_PID" ] && ! kill -0 "$PARAKEET_PID" 2>/dev/null; then
      echo "engine: parakeet died, restarting it" >&2
      start_parakeet
    fi
    if ! curl -fsS -o /dev/null --max-time 10 "http://127.0.0.1:8977/" 2>/dev/null; then
      echo "engine: decoder stopped answering, cycling it" >&2
      kill -9 "$DECODER_PID" 2>/dev/null || true
      sleep 2
      start_decoder
    fi
  done
}
supervise_decoder &

exec uvicorn gate:app --host 0.0.0.0 --port "${PORT:-8080}"
