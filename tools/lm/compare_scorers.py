#!/usr/bin/env python3
"""Compare the neural LM and the n-gram model head-to-head on specific candidates.

Answers "does the neural model rank <gold> above <what I typed>, given this context?"
INDEPENDENT of the on-device trie generator — you pass the candidate words explicitly,
so you can probe words the fuzzy search would never even produce (e.g. a first-letter
typo like 'js' -> 'is', which the channel model prices out of the candidate list).

Scores shown per candidate:
  ngram        stupid-backoff log-prob from langdata.bin (+ base counts only)
  neural(sum)  summed token log-prob  — this is what the DEVICE uses (NeuralScorer.scores)
  neural/tok   length-normalised      — fairer across different piece counts
  blend        neural_weight*neural(sum) + (1-w)*ngram

Run with the env that has torch + sentencepiece, e.g.:
  /Users/meher/anaconda3/envs/ml/bin/python compare_scorers.py "what" is js just it
  ... --model-dir data/backup_20260707     # the currently-shipped model
  ... --model-dir data                      # the freshly-retrained model
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from eval_harness import LangData, LANGDATA, logprob   # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("context", help="left context words, quoted, e.g. \"what\"")
    ap.add_argument("candidates", nargs="+", help="candidate words to score")
    ap.add_argument("--model-dir", default=str(HERE / "data"),
                    help="dir with spm.model + lm.pt (default: data)")
    ap.add_argument("--neural-weight", type=float, default=0.7)
    args = ap.parse_args()

    ctx = [w.lower() for w in args.context.split()]
    cands = [c.lower() for c in args.candidates]
    ld = LangData(LANGDATA)
    ng = {c: logprob(ld, c, ctx) for c in cands}

    import sentencepiece as spm
    import torch
    from model import TinyLM
    md = Path(args.model_dir)
    sp = spm.SentencePieceProcessor(model_file=str(md / "spm.model"))
    ckpt = torch.load(md / "lm.pt", map_location="cpu")
    nm = TinyLM(vocab=ckpt["vocab"])
    nm.load_state_dict(ckpt["model"])
    nm.eval()
    L, PAD = nm.maxlen, 3

    def neural_lp(w):
        ids = sp.encode("<en> " + " ".join(ctx))
        cand = sp.encode(" " + w)
        seq = (ids + cand)[-L:]
        cstart = len(seq) - len(cand)
        row = seq + [PAD] * (L - len(seq))
        with torch.no_grad():
            lp = torch.log_softmax(nm(torch.tensor([row]))[0], -1)
        total = sum(lp[cstart - 1 + i, t].item() for i, t in enumerate(cand))
        return total, total / max(len(cand), 1), len(cand)

    w = args.neural_weight
    rows = []
    for c in cands:
        nsum, ntok, npc = neural_lp(c)
        rows.append((c, ng[c], nsum, ntok, w * nsum + (1 - w) * ng[c], npc))

    print(f'\ncontext: "{" ".join(ctx)}"    model: {md.name}    neural-weight: {w}\n')
    print(f'{"cand":12} {"ngram":>8} {"neural(sum)":>12} {"neural/tok":>11} {"blend":>8} {"pieces":>7}')
    print("-" * 62)
    for c, g, nsum, ntok, blend, npc in sorted(rows, key=lambda r: -r[4]):
        print(f"{c:12} {g:8.2f} {nsum:12.2f} {ntok:11.2f} {blend:8.2f} {npc:7d}")

    def order(idx):
        return " > ".join(c for c, *_ in sorted(rows, key=lambda r: r[idx], reverse=True))
    print(f"\nrank by ngram : {order(1)}")
    print(f"rank by neural: {order(2)}   (summed — device order)")
    print(f"rank by blend : {order(4)}")


if __name__ == "__main__":
    main()
