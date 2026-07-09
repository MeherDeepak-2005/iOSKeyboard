#!/usr/bin/env python3
"""Compare two (spm.model, lm.pt) pairs on a held-out register file.

Reports per-WORD perplexity — per-token ppl is meaningless across different
tokenizers (a tokenizer that splits words into more pieces gets an unearned
advantage), so the log-prob mass of each line is normalized by its word count.
Both models are scored on the IDENTICAL line set: any line that exceeds the
32-token window under EITHER tokenizer is skipped for both.

Usage:
  python3 eval_register.py data/messaging_heldout.txt data/backup_20260707 data
"""

import math
import sys
from pathlib import Path

import sentencepiece as spm
import torch
import torch.nn.functional as F

from model import TinyLM
from prepare_data import clean

L = 32
SEQ = L + 1
PAD = 3


def load(d):
    d = Path(d)
    sp = spm.SentencePieceProcessor(model_file=str(d / "spm.model"))
    ckpt = torch.load(d / "lm.pt", map_location="cpu")
    m = TinyLM(vocab=ckpt["vocab"])
    m.load_state_dict(ckpt["model"])
    m.eval()
    return sp, m


def line_nll(sp, m, line):
    """Total negative log-likelihood of the line's tokens given the <en> tag."""
    ids = sp.encode("<en> " + line) + [sp.eos_id()]
    if len(ids) > SEQ:
        return None
    real = len(ids) - 1
    padded = ids + [PAD] * (SEQ - len(ids))
    x = torch.tensor([padded])
    with torch.no_grad():
        logits = m(x[:, :-1])
    tgt = x[:, 1:].clone()
    tgt[:, real:] = -100
    return F.cross_entropy(logits.reshape(-1, logits.shape[-1]),
                           tgt.reshape(-1), reduction="sum", ignore_index=-100).item()


def main():
    heldout, dir_a, dir_b = sys.argv[1], sys.argv[2], sys.argv[3]
    sp_a, m_a = load(dir_a)
    sp_b, m_b = load(dir_b)

    lines = []
    for raw in Path(heldout).open(errors="replace"):
        if (s := clean(raw)) is not None:
            lines.append(s)
    print(f"{len(lines)} cleaned held-out lines")

    nll = {dir_a: 0.0, dir_b: 0.0}
    words = 0
    used = 0
    for s in lines:
        a = line_nll(sp_a, m_a, s)
        b = line_nll(sp_b, m_b, s)
        if a is None or b is None:      # over-window under either tokenizer: skip both
            continue
        nll[dir_a] += a
        nll[dir_b] += b
        words += len(s.split()) + 1     # +1: the eos the model must also predict
        used += 1

    print(f"{used} lines scored ({words} words incl. eos)")
    for d in (dir_a, dir_b):
        print(f"  {d}: per-word ppl {math.exp(nll[d] / words):.1f}")


if __name__ == "__main__":
    main()
