#!/usr/bin/env python3
"""Build a fine-tune dataset from vocab/correction pairs.

Runs on macOS using the system `say` voices, so dataset generation costs
nothing. Each vocab term is embedded in varied carrier sentences, spoken by
several voices at several rates, and written as 16 kHz mono WAV plus a
manifest.jsonl of {"audio": path, "text": transcript} lines.

Vocab file format, one per line (learned-words format also accepted):
    NessoTalk
    NessoTalk|nesso talk,neso talk   # variants are ignored here; the
                                     # CANONICAL is what the model must learn
"""

import argparse
import json
import random
import subprocess
import sys
from pathlib import Path

CARRIERS = [
    "I was just telling them about {t} yesterday.",
    "Can you open {t} and check the settings?",
    "The {t} update ships on Tuesday.",
    "We should move that conversation over to {t}.",
    "She asked whether {t} works on Windows too.",
    "Let me know once {t} is back up.",
    "I pasted the numbers straight into {t}.",
    "Honestly {t} handled it better than I expected.",
    "Send the invoice through {t} before five.",
    "My notes on {t} are in the shared folder.",
]

VOICES = ["Samantha", "Alex", "Daniel", "Karen", "Moira", "Rishi"]
RATES = [165, 185, 210]


def synth(text: str, voice: str, rate: int, wav: Path) -> bool:
    aiff = wav.with_suffix(".aiff")
    try:
        subprocess.run(
            ["say", "-v", voice, "-r", str(rate), "-o", str(aiff), text],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
             str(aiff), str(wav)],
            check=True, capture_output=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False
    finally:
        aiff.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocab", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--per-term", type=int, default=6,
                    help="voice/rate/carrier combinations per term")
    ap.add_argument("--mix", default=None,
                    help="general-speech manifest.jsonl to blend in ~9:1")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    random.seed(args.seed)
    out = Path(args.out)
    (out / "wav").mkdir(parents=True, exist_ok=True)

    terms = []
    for line in Path(args.vocab).read_text().splitlines():
        line = line.split("#")[0].strip()
        if not line:
            continue
        terms.append(line.split("|")[0].strip())

    rows = []
    for term in terms:
        combos = [(v, r, c) for v in VOICES for r in RATES for c in CARRIERS]
        random.shuffle(combos)
        made = 0
        for voice, rate, carrier in combos:
            if made >= args.per_term:
                break
            text = carrier.format(t=term)
            wav = out / "wav" / f"{term.lower().replace(' ', '_')}_{made}.wav"
            if synth(text, voice, rate, wav):
                rows.append({"audio": str(wav), "text": text})
                made += 1
        if made == 0:
            print(f"warning: no audio produced for {term!r}", file=sys.stderr)

    if args.mix:
        general = [json.loads(l) for l in Path(args.mix).read_text().splitlines() if l.strip()]
        want = len(rows) * 9
        rows += random.sample(general, min(want, len(general)))
        if len(general) < want:
            print(f"warning: wanted {want} general rows, only {len(general)} "
                  "available; the blend is vocab-heavier than 9:1",
                  file=sys.stderr)

    random.shuffle(rows)
    manifest = out / "manifest.jsonl"
    manifest.write_text("".join(json.dumps(r) + "\n" for r in rows))
    print(f"{len(rows)} rows -> {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
