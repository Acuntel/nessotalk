#!/usr/bin/env python3
"""LoRA fine-tune of the NessoTalk engine model.

Train mode:  python3 finetune.py --manifest dataset/manifest.jsonl --out checkpoints/
Merge mode:  python3 finetune.py --merge checkpoints/ --out merged/

Runs on one rented GPU (A10/T4/4090 class). Prints held-out WER before and
after training; ship only if vocab WER drops and general WER holds. The merged
output is a plain HF whisper model ready for ggml conversion (see README).
"""

import argparse
import json
import random
from pathlib import Path

import torch

BASE = "openai/whisper-large-v3-turbo"


def load_rows(manifest: str):
    rows = [json.loads(l) for l in Path(manifest).read_text().splitlines() if l.strip()]
    random.seed(7)
    random.shuffle(rows)
    n_eval = max(8, len(rows) // 20)
    return rows[n_eval:], rows[:n_eval]


def make_dataset(rows, processor):
    import soundfile as sf
    from datasets import Dataset

    def gen():
        for r in rows:
            audio, sr = sf.read(r["audio"])
            if sr != 16000:
                continue
            feats = processor.feature_extractor(
                audio, sampling_rate=16000
            ).input_features[0]
            labels = processor.tokenizer(r["text"]).input_ids
            yield {"input_features": feats, "labels": labels}

    return Dataset.from_generator(gen)


def wer_of(model, processor, rows) -> float:
    import jiwer
    import soundfile as sf

    model.eval()
    hyps, refs = [], []
    with torch.no_grad():
        for r in rows:
            audio, sr = sf.read(r["audio"])
            if sr != 16000:
                continue
            feats = processor.feature_extractor(
                audio, sampling_rate=16000, return_tensors="pt"
            ).input_features.to(model.device, dtype=model.dtype)
            ids = model.generate(feats, language="en", task="transcribe")
            hyps.append(processor.batch_decode(ids, skip_special_tokens=True)[0])
            refs.append(r["text"])
    return jiwer.wer(refs, hyps)


def train(args) -> None:
    from peft import LoraConfig, get_peft_model
    from transformers import (
        Seq2SeqTrainer,
        Seq2SeqTrainingArguments,
        WhisperForConditionalGeneration,
        WhisperProcessor,
    )

    processor = WhisperProcessor.from_pretrained(BASE)
    model = WhisperForConditionalGeneration.from_pretrained(
        BASE, torch_dtype=torch.float16, device_map="auto"
    )

    train_rows, eval_rows = load_rows(args.manifest)
    print(f"train={len(train_rows)} eval={len(eval_rows)}")
    print(f"WER before: {wer_of(model, processor, eval_rows):.3f}")

    lora = LoraConfig(
        r=16, lora_alpha=32, lora_dropout=0.05,
        target_modules=["q_proj", "v_proj"],
    )
    model = get_peft_model(model, lora)
    model.print_trainable_parameters()

    class Collator:
        def __call__(self, features):
            batch = processor.feature_extractor.pad(
                [{"input_features": f["input_features"]} for f in features],
                return_tensors="pt",
            )
            labels = processor.tokenizer.pad(
                [{"input_ids": f["labels"]} for f in features],
                return_tensors="pt",
            )
            ids = labels["input_ids"].masked_fill(
                labels["attention_mask"].ne(1), -100
            )
            batch["labels"] = ids
            return batch

    trainer = Seq2SeqTrainer(
        model=model,
        args=Seq2SeqTrainingArguments(
            output_dir=args.out,
            per_device_train_batch_size=8,
            gradient_accumulation_steps=2,
            learning_rate=1e-4,
            num_train_epochs=args.epochs,
            fp16=True,
            logging_steps=10,
            save_strategy="no",
            report_to=[],
        ),
        train_dataset=make_dataset(train_rows, processor),
        data_collator=Collator(),
    )
    trainer.train()
    model.save_pretrained(args.out)
    print(f"WER after: {wer_of(model, processor, eval_rows):.3f}")
    print(f"adapter saved to {args.out}")


def merge(args) -> None:
    from peft import PeftModel
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    base = WhisperForConditionalGeneration.from_pretrained(
        BASE, torch_dtype=torch.float16
    )
    merged = PeftModel.from_pretrained(base, args.merge).merge_and_unload()
    merged.save_pretrained(args.out, safe_serialization=False)
    WhisperProcessor.from_pretrained(BASE).save_pretrained(args.out)
    print(f"merged model saved to {args.out}; convert with "
          "whisper.cpp/models/convert-h5-to-ggml.py (see README)")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest")
    ap.add_argument("--merge", help="adapter dir to merge into the base model")
    ap.add_argument("--out", required=True)
    ap.add_argument("--epochs", type=int, default=3)
    args = ap.parse_args()
    if args.merge:
        merge(args)
    elif args.manifest:
        train(args)
    else:
        ap.error("need --manifest (train) or --merge (export)")


if __name__ == "__main__":
    main()
