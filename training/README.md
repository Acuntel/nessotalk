# Cooking the NessoTalk model

This directory turns the base engine weights into NessoTalk's own model.
The flywheel: the app's learned-dictionary system already collects
mishear-to-correction pairs (`NessoTalk|nesso talk,neso talk`). Those pairs are
exactly the words generic speech models get wrong for our users. We synthesize
speech for them, fine-tune, and serve the result from the engine. More users,
more corrections, better model, and the model only ever exists on our side.

## The recipe

**1. Build the dataset (runs on the Mac, free):**

```
python3 build_dataset.py \
  --vocab vocab.txt \
  --out dataset/ \
  --per-term 6
```

`vocab.txt` takes one entry per line, either a bare term (`NessoTalk`) or the
learned-words format (`NessoTalk|nesso talk,neso talk`). The script wraps each
term in varied carrier sentences, synthesizes audio with several system voices
at several rates, and writes `dataset/manifest.jsonl` with 16 kHz mono WAVs.

Synthetic-only fine-tuning makes a model that is great at your vocab and worse
at everything else. Keep it honest: `--mix path/to/general_manifest.jsonl`
blends in general speech (Common Voice or LibriSpeech excerpts) at roughly
9:1 general-to-vocab. LoRA with a low learning rate is the second guard.

**2. Fine-tune (one rented GPU, roughly $5-20 once):**

Any single A10/T4/4090 box (RunPod, Lambda, Colab Pro) with
`pip install torch transformers peft datasets evaluate jiwer soundfile`:

```
python3 finetune.py --manifest dataset/manifest.jsonl --out checkpoints/
python3 finetune.py --merge checkpoints/ --out merged/
```

The first command trains a LoRA adapter and prints held-out WER before and
after, which is the go/no-go number: ship only if vocab WER drops and general
WER does not rise more than a point.

**3. Export to engine weights:**

```
git clone --depth 1 https://github.com/ggml-org/whisper.cpp
python3 whisper.cpp/models/convert-h5-to-ggml.py merged/ whisper.cpp/models/ .
./whisper.cpp/build/bin/quantize ggml-model.bin nessotalk-engine-v2-q5_0.bin q5_0
```

**4. Ship it (no client update, no downtime):**

```
gh release create engine-v2 --repo Acuntel/nessotalk \
  nessotalk-engine-v2-q5_0.bin nessotalk-vad-v1.bin
railway variables --set MODEL_TAG=engine-v2 && railway redeploy
```

The fleet is on the new model the moment the service restarts. Rolling back is
setting `MODEL_TAG=engine-v1` again.

## Rules

- Correction pairs are TEXT data we already have; never pull customer AUDIO
  into a dataset without an explicit opt-in. The site promises audio is
  discarded, and that promise holds here too.
- Keep the dictionary describing observed reality: only real mishearings go in
  vocab files, no speculative variants.
