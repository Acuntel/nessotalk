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

# Resident decoder on localhost only. The gate below is the only public
# surface, so an unlicensed request never reaches the model at all.
whisper-server \
  -m "$MODEL_DIR/nessotalk-engine-${MODEL_TAG#engine-}-q5_0.bin" \
  --host 127.0.0.1 --port 8977 -t "${WHISPER_THREADS:-8}" \
  --vad -vm "$MODEL_DIR/nessotalk-vad-v1.bin" -vt "${VAD_THRESHOLD:-0.15}" &

for _ in $(seq 1 180); do
  curl -fsS -o /dev/null "http://127.0.0.1:8977/" 2>/dev/null && break
  sleep 1
done

exec uvicorn gate:app --host 0.0.0.0 --port "${PORT:-8080}"
