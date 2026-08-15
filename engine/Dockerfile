# NessoTalk Engine: our own hosted speech-to-text service.
#
# TWO decoders behind ONE license gate, both bound to localhost. gate.py is the
# only public surface, so an unlicensed request never reaches either model.
#
#   parakeet-server  :8978  English and 24 other European languages. Primary.
#   whisper-server   :8977  Everything else, and the fallback if parakeet dies.
#
# Why two. Measured CPU to CPU on identical hardware, 4 threads, no GPU:
#   4.4s clip   whisper 18.20s   parakeet-0.6b-v3 0.85s
#   35.5s clip  whisper 37.69s   parakeet-0.6b-v3 8.84s
#   4 parallel  whisper 13s      parakeet-0.6b-v3 3.49s
# Parakeet also has no 30-second encoder window, so it keeps spans that whisper
# silently drops at the boundary. Our test clip loses "and it absolutely cannot
# require anyone" on whisper and retains it on parakeet.
#
# Whisper stays because parakeet covers 25 languages and whisper covers 99, and
# because parakeet cannot be told which language to expect. ENGINE=whisper routes
# everything back to whisper without a code change.

# --- parakeet: lift the prebuilt binary rather than compiling ggml twice ---
# Pinned deliberately. parakeet.cpp is young (v0.5.0, pre-1.0); `latest` moving
# under us is not a risk worth taking on a decoder.
FROM ghcr.io/mudler/parakeet.cpp-server:v0.5.0 AS parakeet

# --- whisper: the decode stack the desktop app proved over a year ---
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/ggml-org/whisper.cpp /src
WORKDIR /src
RUN cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    && cmake --build build --config Release -j --target whisper-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip curl ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --break-system-packages --no-cache-dir \
       fastapi uvicorn python-multipart httpx
COPY --from=build /src/build/bin/whisper-server /usr/local/bin/whisper-server
# parakeet-server links against shared ggml, so the libs travel with the binary.
COPY --from=parakeet /usr/local/bin/parakeet-server /usr/local/bin/parakeet-server
COPY --from=parakeet /usr/local/lib/libggml.so.0 /usr/local/lib/
COPY --from=parakeet /usr/local/lib/libggml-cpu.so.0 /usr/local/lib/
COPY --from=parakeet /usr/local/lib/libggml-base.so.0 /usr/local/lib/
RUN ldconfig
WORKDIR /app
COPY gate.py boot.sh ./
RUN chmod +x boot.sh
ENV MODEL_DIR=/models
CMD ["./boot.sh"]
