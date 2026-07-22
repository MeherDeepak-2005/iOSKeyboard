#!/usr/bin/env python3
"""Evaluate a trained GRU (or any model load_inference_checkpoint understands).

Three numbers that matter for a search-prior LM:
  1. Held-out perplexity on the messaging register (data/messaging_heldout.txt).
  2. Next-token top-1 / top-5 accuracy on the same set — the "did it predict the word"
     signal that maps to keystroke savings, reported both over all tokens and over
     word-initial tokens only (the ones the keyboard actually competes on).
  3. A streaming-parity assertion: forward_step threaded token-by-token must equal the
     batched forward within tolerance, or the in-loop deployment path is not the model
     you trained.

  python eval_gru.py --checkpoint data/gru.pt
"""

import argparse
from pathlib import Path

import sentencepiece as spm
import torch
import torch.nn.functional as F

try:
    from tqdm.auto import tqdm
except ImportError:
    def tqdm(iterable=None, **kwargs):
        return iterable if iterable is not None else []

from model import KeyboardGRULM, load_inference_checkpoint

DATA = Path(__file__).resolve().parent / "data"


def perplexity_and_accuracy(model, sp, lines, device):
    total_nll, total_tokens = 0.0, 0
    top1 = top5 = top1_word = word_tokens = 0
    with torch.no_grad():
        for line in tqdm(lines, desc="eval", unit="line", dynamic_ncols=True):
            ids = sp.encode(line) + [sp.eos_id()]
            if len(ids) < 2:
                continue
            x = torch.tensor([ids], device=device)
            logits = model(x[:, :-1])                       # [1, L-1, V]
            targets = x[0, 1:]
            log_probs = F.log_softmax(logits[0], dim=-1)
            total_nll -= log_probs[torch.arange(len(targets)), targets].sum().item()
            total_tokens += len(targets)
            ranked = logits[0].argsort(dim=-1, descending=True)
            hit1 = ranked[:, 0] == targets
            hit5 = (ranked[:, :5] == targets.unsqueeze(1)).any(dim=1)
            top1 += hit1.sum().item()
            top5 += hit5.sum().item()
            # Word-initial = the predicted piece begins a new word (SentencePiece "▁").
            pieces = [sp.id_to_piece(int(t)) for t in targets]
            word_start = torch.tensor([p.startswith("▁") for p in pieces], device=device)
            top1_word += (hit1 & word_start).sum().item()
            word_tokens += word_start.sum().item()
    ppl = float(torch.tensor(total_nll / max(total_tokens, 1)).exp())
    return {
        "tokens": total_tokens,
        "ppl": ppl,
        "top1": top1 / max(total_tokens, 1),
        "top5": top5 / max(total_tokens, 1),
        "top1_word_initial": top1_word / max(word_tokens, 1),
    }


def check_streaming_parity(model, sp, sample, device):
    ids = torch.tensor([sp.encode(sample)[:model.maxlen]], device=device)
    with torch.no_grad():
        full = model(ids)[0]                                # [L, V]
        state = model.empty_state(batch=1)
        step_logits = []
        for position in range(ids.shape[1]):
            logits, state = model.forward_step(ids[:, position], state)
            step_logits.append(logits[0])
        streamed = torch.stack(step_logits)
    return float((full - streamed).abs().max())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=Path, default=DATA / "gru.pt")
    ap.add_argument("--heldout", type=Path, default=DATA / "messaging_heldout.txt")
    ap.add_argument("--device", default="cpu", choices=["cpu", "mps", "cuda"])
    ap.add_argument("--max-lines", type=int, default=0)
    ap.add_argument("--tokenizer", type=Path, default=DATA / "spm.model",
                    help="MUST match the checkpoint's tokenizer (qwen_spm.model for a distilled GRU)")
    args = ap.parse_args()

    sp = spm.SentencePieceProcessor(model_file=str(args.tokenizer))
    model, _ = load_inference_checkpoint(args.checkpoint)
    model = model.to(args.device).eval()

    lines = [line for line in args.heldout.read_text(errors="replace").splitlines() if line.strip()]
    if args.max_lines:
        lines = lines[:args.max_lines]

    stats = perplexity_and_accuracy(model, sp, lines, args.device)
    drift = check_streaming_parity(model, sp, lines[0] if lines else "hello there", args.device)

    print(f"checkpoint         {args.checkpoint}")
    print(f"held-out lines     {len(lines)}  ({stats['tokens']} tokens)")
    print(f"perplexity         {stats['ppl']:.2f}")
    print(f"next-token top-1   {stats['top1']*100:.1f}%")
    print(f"next-token top-5   {stats['top5']*100:.1f}%")
    print(f"word-initial top-1 {stats['top1_word_initial']*100:.1f}%")
    print(f"streaming drift    {drift:.2e}  ({'OK' if drift < 1e-3 else 'FAIL — forward_step != forward'})")


if __name__ == "__main__":
    main()
