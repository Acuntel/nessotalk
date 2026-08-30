// Bridging header for the real-time VAD gate on the waveform (WaveformView /
// AudioCapturer in ptt-dictate.swift). Links directly against whisper.cpp's
// own libwhisper — the same Silero VAD model already used for anti-
// hallucination decoding — so the waveform's gate is genuine speech
// detection, in-process, with no per-check subprocess spawn.
#include <whisper.h>
#include <ggml-backend.h>
