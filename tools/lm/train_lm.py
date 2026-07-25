#!/usr/bin/env python3
"""Train TinyLM on the tagged corpus. Next-token prediction, packed sequences.

At 4.7M params this converges in hours on one consumer GPU (fine on Apple
Silicon MPS too, slower). Reports validation perplexity PER REGISTER — a single
blended number hides Telugu regressions behind English volume.
"""

import argparse
import math
import random
from pathlib import Path

import sentencepiece as spm
import torch
import torch.nn.functional as F

from model import TinyLM

DATA = Path(__file__).resolve().parent / "data"
L = 32                    # fixed model length (must match TinyLM.maxlen / export)
SEQ = L + 1               # pack one extra token for the shifted target


def load_batches(sp, path, batch_tokens=65536, val_every=50, max_lines=0):
    """Yield (train, {tag: val_lines}) packed [B, SEQ] batches, streaming."""
    val = {"<en>": [], "<te>": [], "<xlit>": [], "<hlit>": []}
    buf, batches = [], []
    lines = path.read_text().splitlines()
    random.Random(0).shuffle(lines)
    if max_lines:
        lines = lines[:max_lines]
    for i, line in enumerate(lines):
        ids = sp.encode(line) + [sp.eos_id()]
        tag = line.split(" ", 1)[0]
        if i % val_every == 0 and len(val.get(tag, [None]*99)) < 2000:
            val[tag].append(ids)
            continue
        buf.extend(ids)
        while len(buf) >= SEQ:
            batches.append(buf[:SEQ]); buf = buf[SEQ:]
            if len(batches) * SEQ >= batch_tokens:
                yield torch.tensor(batches), None
                batches = []
    yield torch.tensor(batches) if batches else None, val


def perplexity(model, seqs, device, pad_id=3):
    """Fixed-length eval: each val sequence is padded/truncated to L+1, and padded
    target positions are ignored (-100) so padding doesn't skew the score."""
    if not seqs:
        return float("nan")
    model.eval(); tot, n = 0.0, 0
    with torch.no_grad():
        for ids in seqs:
            ids = ids[:SEQ]
            if len(ids) < 2:
                continue
            real = len(ids) - 1
            padded = ids + [pad_id] * (SEQ - len(ids))
            x = torch.tensor([padded], device=device)
            logits = model(x[:, :-1])
            tgt = x[:, 1:].clone()
            tgt[:, real:] = -100                      # ignore padding positions
            loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]),
                                   tgt.reshape(-1), reduction="sum", ignore_index=-100)
            tot += loss.item(); n += real
    model.train()
    return math.exp(tot / max(n, 1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--finetune", action="store_true",
                    help="resume data/lm.pt and adapt on data/finetune.txt at low LR "
                         "(register adaptation toward texting)")
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"],
                    help="force a device; 'cpu' is slower but reliable when MPS is wedged")
    ap.add_argument("--max-lines", type=int, default=0, help="cap corpus lines (0 = all)")
    ap.add_argument("--batch-tokens", type=int, default=65536)
    args = ap.parse_args()

    corpus = DATA / ("finetune.txt" if args.finetune else "corpus.txt")
    device = (args.device if args.device != "auto"
              else "cuda" if torch.cuda.is_available()
              else "mps" if torch.backends.mps.is_available() else "cpu")
    sp = spm.SentencePieceProcessor(model_file=str(DATA / "spm.model"))
    model = TinyLM(vocab=sp.vocab_size()).to(device)
    if args.finetune:
        model.load_state_dict(torch.load(DATA / "lm.pt", map_location=device)["model"])
        args.lr = min(args.lr, 5e-5)          # gentle — don't wipe pretrained knowledge
        print("fine-tuning from lm.pt")
    print(f"{sum(p.numel() for p in model.parameters())/1e6:.2f}M params on {device}")

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)
    step, val = 0, None
    for epoch in range(args.epochs):
        for batch, v in load_batches(sp, corpus, batch_tokens=args.batch_tokens,
                                     max_lines=args.max_lines):
            if v is not None:
                val = v
            if batch is None or batch.numel() == 0:
                continue
            batch = batch.to(device)
            logits = model(batch[:, :-1])
            loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]),
                                   batch[:, 1:].reshape(-1))
            opt.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); step += 1
            if step % 100 == 0:
                print(f"epoch {epoch} step {step} loss {loss.item():.3f}", flush=True)
            # Checkpoint mid-epoch too — an interruption shouldn't wipe an epoch of work.
            if step % 1000 == 0:
                torch.save({"model": model.state_dict(), "vocab": sp.vocab_size()}, DATA / "lm.pt")
        if val:
            for tag, seqs in val.items():
                print(f"  val ppl {tag}: {perplexity(model, seqs, device):.1f}", flush=True)
        torch.save({"model": model.state_dict(), "vocab": sp.vocab_size()}, DATA / "lm.pt")
    print("saved", DATA / "lm.pt", flush=True)


if __name__ == "__main__":
    main()
