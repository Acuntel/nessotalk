# NessoTalk Engine: our own hosted speech-to-text service.
#
# whisper.cpp server (the same decode stack the desktop app proved for a year)
# running resident behind a license gate. Model weights are pulled at boot from
# the private GitHub Release, never baked into the image and never shipped to a
# customer machine. Revoke the repo token and the model is unreachable.
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
WORKDIR /app
COPY gate.py boot.sh ./
RUN chmod +x boot.sh
ENV MODEL_DIR=/models
CMD ["./boot.sh"]
