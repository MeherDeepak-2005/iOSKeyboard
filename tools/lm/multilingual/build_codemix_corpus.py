#!/usr/bin/env python3
"""Build the code-mixed GRU corpus: register-tagged, cleaned, deduped, split.

This is the ONLY new data step needed to take the verified monolingual GRU to a
trilingual (English / romanized Hindi / romanized Telugu) one. It emits exactly the
format ``train_gru.py`` + ``train_lm.load_batches`` already consume — one
register-tagged sentence per line, e.g.::

    <en>   see you tomorrow at the station
    <hlit> bhai kal milte hai station pe
    <xlit> nuvvu repu station daggara kalustava

Register tags condition the model from token one (they are SentencePiece
user-defined symbols), so the model learns per-language priors AND still
code-switches *within* a line — the exact mechanism the existing ``<en>/<te>/<xlit>``
setup uses. ``<xlit>`` is REUSED for romanized Telugu (Tenglish); ``<hlit>`` is new
for romanized Hindi (Hinglish). ``<te>`` (native Telugu script) is untouched.

Inputs are language-SORTED files (you tell it which language each file is), because
romanized Hindi/Telugu is Latin script and fastText LID *cannot* positively identify
it — CC-100's ``hi_rom``/``te_rom`` splits and Sangraha's romanized subset are already
sorted at the source, so we trust that and only use LID (optional) to REJECT obvious
native-script / other-language noise. Do not believe any pipeline that claims to LID
romanized text into buckets; it will silently mislabel most of it.

  python build_codemix_corpus.py \
      --en   ../data/corpus.txt \
      --hlit raw/cc100_hi_rom.txt.xz raw/hinglish_*.txt \
      --xlit raw/cc100_te_rom.txt.xz raw/tenglish_*.txt \
      [--lid-model raw/lid.176.bin] [--max-per-register 1500000] [--val-per-register 2000]

Outputs (into ../data, where train_gru.py looks):
  corpus_mix.txt       the training corpus (shuffled at train time by load_batches)
  corpus_mix.val.txt   a held-out slice per register (never seen in training)
"""

import argparse
import gzip
import hashlib
import lzma
import random
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA = HERE.parent / "data"                     # tools/lm/data — train_gru.py reads here

# Romanized Hindi/Telugu and English are all Latin, so one cleaner covers all three.
# Mirrors prepare_data.clean(): lowercase, drop URLs/emails, keep [a-z' ], collapse.
URL_RE = re.compile(r"https?://\S+|www\.\S+|\S+@\S+")
KEEP = re.compile(r"[^a-z' ]+")
SPACES = re.compile(r"\s+")
TAG_STRIP = re.compile(r"^<(en|te|xlit|hlit)>\s*")  # tolerate pre-tagged inputs (e.g. corpus.txt)

TAGS = {"en": "<en>", "hlit": "<hlit>", "xlit": "<xlit>"}


def open_text(path: Path):
    """Stream a .txt / .gz / .xz file as text, decompressing incrementally."""
    if path.suffix == ".xz":
        return lzma.open(path, "rt", encoding="utf-8", errors="replace")
    if path.suffix == ".gz":
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    return path.open("r", encoding="utf-8", errors="replace")


def clean(line: str) -> str | None:
    s = TAG_STRIP.sub("", line.strip())
    s = URL_RE.sub(" ", s.lower())
    s = KEEP.sub(" ", s)
    s = SPACES.sub(" ", s).strip()
    n = len(s.split())
    if not (3 <= n <= 40):                       # skip headers, dumps, single interjections
        return None
    # Guard against lines that survived cleaning but are mostly stripped punctuation
    # (common in scraped social text): require the kept text to be substantial.
    return s if len(s) >= 6 else None


def load_lid(path: Path):
    try:
        import fasttext                          # optional dep; only needed with --lid-model
    except ImportError:
        raise SystemExit("--lid-model needs fasttext:  pip install fasttext-wheel")
    import warnings
    warnings.filterwarnings("ignore")
    return fasttext.load_model(str(path))


# Languages whose fastText label, at high confidence on a Latin-script line, means the
# line is NOT the romanized target we want (leaked native script, or a different
# language entirely). We REJECT these; we never try to positively accept romanized text.
_REJECT_LANGS = {"hi", "te", "ta", "kn", "ml", "bn", "gu", "mr", "pa", "ur", "ne",
                 "ar", "fa", "ru", "zh", "ja", "ko", "th", "he", "el"}


def lid_rejects(model, s: str, thresh: float) -> bool:
    lab, prob = model.predict(s.replace("\n", " "), k=1)
    lang = lab[0].removeprefix("__label__")
    return lang in _REJECT_LANGS and prob[0] >= thresh


def collect(files, tag, seen, lid, thresh, cap):
    """Clean + dedupe (global) + cap one register. Returns a list of `<tag> sentence`."""
    out = []
    for name in files:
        path = Path(name)
        if not path.exists():
            print(f"  skip (missing): {path}")
            continue
        kept = 0
        with open_text(path) as fh:
            for raw in fh:
                if len(out) >= cap:
                    break
                s = clean(raw)
                if s is None:
                    continue
                if lid is not None and lid_rejects(lid, s, thresh):
                    continue
                h = hashlib.blake2b(s.encode(), digest_size=8).digest()
                if h in seen:
                    continue
                seen.add(h)
                out.append(f"{tag} {s}")
                kept += 1
        print(f"  {path.name}: +{kept} lines ({tag})")
        if len(out) >= cap:
            print(f"  reached --max-per-register cap ({cap}) for {tag}")
            break
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--en", nargs="*", default=[], help="English file(s) -> <en>")
    ap.add_argument("--hlit", nargs="*", default=[], help="romanized Hindi file(s) -> <hlit>")
    ap.add_argument("--xlit", nargs="*", default=[], help="romanized Telugu file(s) -> <xlit>")
    ap.add_argument("--max-per-register", type=int, default=1_500_000,
                    help="cap lines per register so English volume can't drown the Indic ones")
    ap.add_argument("--val-per-register", type=int, default=2000,
                    help="held-out lines per register, written to corpus_mix.val.txt")
    ap.add_argument("--lid-model", type=Path, default=None,
                    help="fastText lid.176.bin; REJECTS native-script/other-language noise only")
    ap.add_argument("--lid-thresh", type=float, default=0.5)
    ap.add_argument("--out", type=Path, default=DATA / "corpus_mix.txt")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    if not (args.en or args.hlit or args.xlit):
        raise SystemExit("give at least one of --en / --hlit / --xlit")

    lid = load_lid(args.lid_model) if args.lid_model else None
    seen: set[bytes] = set()                     # global dedupe across every register
    registers = [("en", args.en), ("hlit", args.hlit), ("xlit", args.xlit)]

    train_lines: list[str] = []
    val_lines: list[str] = []
    rng = random.Random(args.seed)
    for key, files in registers:
        if not files:
            continue
        print(f"[{key}]")
        lines = collect(files, TAGS[key], seen, lid, args.lid_thresh, args.max_per_register)
        rng.shuffle(lines)                       # so the val slice is a random sample, not the file head
        n_val = min(args.val_per_register, len(lines) // 10)
        val_lines.extend(lines[:n_val])
        train_lines.extend(lines[n_val:])
        print(f"  -> {len(lines) - n_val} train / {n_val} val")

    if not train_lines:
        raise SystemExit("no lines survived cleaning — check inputs")

    args.out.write_text("\n".join(train_lines) + "\n")
    val_path = args.out.with_suffix(".val.txt")
    val_path.write_text("\n".join(val_lines) + "\n")
    print(f"\nwrote {args.out} ({len(train_lines)} lines)")
    print(f"wrote {val_path} ({len(val_lines)} lines)")
    # Register mix — watch this: if <en> dwarfs the others the model forgets the Indic
    # registers between checkpoints. Raise --max-per-register on the minority side or
    # cap English to rebalance.
    from collections import Counter
    mix = Counter(l.split(" ", 1)[0] for l in train_lines)
    print("register mix:", dict(mix))


if __name__ == "__main__":
    main()
