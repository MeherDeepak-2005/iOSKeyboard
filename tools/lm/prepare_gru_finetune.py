#!/usr/bin/env python3
"""Build data/gru_finetune.txt — the messaging-register adaptation set for the GRU.

The GRU pretrains on the broad tagged corpus.txt, then fine-tunes toward the texting
register the keyboard actually sees. That register already lives in the repo as
data/dailydialog.txt and data/sms_train.txt; this tags each line ``<en>`` (matching
corpus.txt so train_gru.py's per-register split still works), lowercases, collapses
whitespace, drops near-duplicates and junk, and writes one combined file. No download.

  python prepare_gru_finetune.py
"""

import re
from pathlib import Path

DATA = Path(__file__).resolve().parent / "data"
SOURCES = ["dailydialog.txt", "sms_train.txt"]
OUT = DATA / "gru_finetune.txt"

TAG = re.compile(r"^<(en|te|xlit)>\s*")
WS = re.compile(r"\s+")


def normalize(line: str) -> str | None:
    line = TAG.sub("", line.strip()).lower()            # strip any pre-existing tag
    line = WS.sub(" ", line).strip()
    words = line.split(" ")
    # 3..40 tokens, mostly letters — skips headers, URLs dumps, and single interjections.
    if not (3 <= len(words) <= 40):
        return None
    letters = sum(c.isalpha() for c in line)
    if letters < 0.6 * len(line.replace(" ", "")):
        return None
    return line


def main() -> None:
    seen: set[str] = set()
    kept: list[str] = []
    for name in SOURCES:
        path = DATA / name
        if not path.exists():
            print(f"skip (missing): {path}")
            continue
        n = 0
        for raw in path.read_text(errors="replace").splitlines():
            norm = normalize(raw)
            if norm is None or norm in seen:
                continue
            seen.add(norm)
            kept.append(f"<en> {norm}")
            n += 1
        print(f"{name}: +{n} lines")
    if not kept:
        raise SystemExit("no messaging lines found — check data/ sources")
    OUT.write_text("\n".join(kept) + "\n")
    print(f"wrote {OUT} ({len(kept)} lines)")


if __name__ == "__main__":
    main()
