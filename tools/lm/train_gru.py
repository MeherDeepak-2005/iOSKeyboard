#!/usr/bin/env python3
"""Train the streaming GRU LM (roadmap Plan 3: the in-loop search-prior challenger).

Same corpus, tokenizer, packing (L=32), and next-token objective as ``train_lm.py``,
so its perplexity is directly comparable to TinyLM / the 10.6M student. Two stages:

  pretrain :  python train_gru.py                         # on data/corpus.txt
  finetune :  python train_gru.py --finetune              # adapt on data/gru_finetune.txt

Checkpoints save the GRUModelConfig so ``load_inference_checkpoint`` reconstructs the
model without a hand-kept architecture. ~2.3M params → converges in ~1-2h on one GPU
(MPS works; CPU is slow but reliable). Reports validation perplexity PER REGISTER.
"""

import argparse
from dataclasses import asdict
from pathlib import Path

import sentencepiece as spm
import torch
import torch.nn.functional as F

try:
    from tqdm.auto import tqdm
except ImportError:                                       # bars degrade to no-ops off Colab
    class tqdm:
        def __init__(self, iterable=None, **kwargs):
            self.iterable = iterable if iterable is not None else []
        def __iter__(self):
            return iter(self.iterable)
        def set_postfix(self, **kwargs):
            pass

from model import GRUModelConfig, KeyboardGRULM, count_parameters
from train_lm import load_batches, perplexity          # shared, model-agnostic helpers

DATA = Path(__file__).resolve().parent / "data"


def resolve_device(choice):
    if choice != "auto":
        return choice
    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=3)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--finetune", action="store_true",
                    help="resume data/gru.pt and adapt on data/gru_finetune.txt at low LR")
    ap.add_argument("--data", type=Path, default=None,
                    help="override corpus (default: corpus.txt, or gru_finetune.txt with --finetune)")
    ap.add_argument("--out", type=Path, default=DATA / "gru.pt")
    ap.add_argument("--device", default="auto", choices=["auto", "cpu", "mps", "cuda"])
    ap.add_argument("--max-lines", type=int, default=0, help="cap corpus lines (0 = all)")
    # The [B, L, vocab] logits (doubled during distillation) dominate GPU memory, not
    # the 2.3M GRU. 32768 fits a 15 GB T4; drop to 16384 if a distill run OOMs.
    ap.add_argument("--batch-tokens", type=int, default=32768)
    ap.add_argument("--layers", type=int, default=2)
    ap.add_argument("--d-model", type=int, default=256)
    ap.add_argument("--tokenizer", type=Path, default=DATA / "spm.model",
                    help="SentencePiece model; with --teacher it MUST match the teacher's")
    ap.add_argument("--teacher", type=Path, default=None,
                    help="distill from this checkpoint (e.g. the 10.6M student) via KL")
    ap.add_argument("--distill-alpha", type=float, default=0.5,
                    help="weight on the hard next-token CE; (1-alpha) rides the teacher KL")
    ap.add_argument("--distill-temp", type=float, default=2.0)
    args = ap.parse_args()

    corpus = args.data or (DATA / ("gru_finetune.txt" if args.finetune else "corpus.txt"))
    if not corpus.exists():
        raise SystemExit(f"missing corpus: {corpus} (run prepare_gru_finetune.py for --finetune)")
    device = resolve_device(args.device)
    sp = spm.SentencePieceProcessor(model_file=str(args.tokenizer))

    config = GRUModelConfig(vocab_size=sp.vocab_size(), d_model=args.d_model,
                            hidden=args.d_model, layers=args.layers)
    model = KeyboardGRULM(config).to(device)
    if args.finetune:
        prior = torch.load(args.out, map_location=device)
        model.load_state_dict(prior["model"])
        args.lr = min(args.lr, 2e-4)                     # gentle — keep pretrained knowledge
        print(f"fine-tuning from {args.out}")
    print(f"{count_parameters(model)/1e6:.2f}M params on {device}", flush=True)

    teacher = None
    if args.teacher:
        from model import load_inference_checkpoint
        teacher, teacher_ck = load_inference_checkpoint(args.teacher)
        teacher = teacher.to(device).eval()
        for parameter in teacher.parameters():
            parameter.requires_grad_(False)
        if teacher_ck.get("model_config", {}).get("vocab_size", sp.vocab_size()) != sp.vocab_size():
            raise SystemExit("teacher/student vocab mismatch — pass the teacher's --tokenizer")
        print(f"distilling from {args.teacher} "
              f"(alpha={args.distill_alpha}, T={args.distill_temp})", flush=True)

    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=0.01)

    def save():
        torch.save({"model": model.state_dict(), "model_type": "gru",
                    "model_config": asdict(config), "vocab": sp.vocab_size()}, args.out)

    step, val = 0, None
    for epoch in range(args.epochs):
        bar = tqdm(load_batches(sp, corpus, batch_tokens=args.batch_tokens,
                                max_lines=args.max_lines),
                   desc=f"epoch {epoch + 1}/{args.epochs}", unit="batch", dynamic_ncols=True)
        for batch, v in bar:
            if v is not None:
                val = v
            if batch is None or batch.numel() == 0:
                continue
            batch = batch.to(device)
            logits = model(batch[:, :-1])
            vocab = logits.shape[-1]
            loss = F.cross_entropy(logits.reshape(-1, vocab), batch[:, 1:].reshape(-1))
            if teacher is not None:
                # Hinton distillation: match the teacher's soft next-token distribution
                # (temperature-scaled KL) alongside the true next token. The T^2 factor
                # keeps the soft-loss gradient magnitude comparable to the hard CE.
                with torch.no_grad():
                    teacher_logits = teacher(batch[:, :-1])
                temp = args.distill_temp
                soft = F.kl_div(
                    F.log_softmax(logits.reshape(-1, vocab) / temp, dim=-1),
                    F.log_softmax(teacher_logits.reshape(-1, vocab) / temp, dim=-1),
                    reduction="batchmean", log_target=True) * (temp * temp)
                loss = args.distill_alpha * loss + (1 - args.distill_alpha) * soft
            opt.zero_grad(set_to_none=True)              # frees grad buffers each step
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            step += 1
            bar.set_postfix(loss=f"{loss.item():.3f}", step=step)
            if step % 1000 == 0:
                save()
        if val:
            for tag, seqs in val.items():
                print(f"  val ppl {tag}: {perplexity(model, seqs, device):.1f}", flush=True)
        save()
    print("saved", args.out, flush=True)


if __name__ == "__main__":
    main()
