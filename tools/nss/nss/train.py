"""Train an NSS word LM from a JSON config.

    python -m nss.train --config configs/cifg-lstm-96x670.json [--out runs/NAME] [--resume]

Config sections: "model" (architecture options, see nss.models), "data" (mixture
weights per source), "train" (batch, bptt, tokens, lr, warmup, clip, weight_decay,
eval_every, seed). Writes runs/NAME/{log.jsonl, last.pt, best.pt, config.json}. best.pt
is chosen on the valid perplexity of word targets, averaged over the valid sets.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import random
import time
from pathlib import Path

import numpy as np
import torch

from . import DATA, RUNS
from .data import Mixture, Shard, lexicon_share
from .losses import cross_entropy_sum
from .metrics import evaluate
from .models import build, detach
from .vocab import BOS, Vocabulary

DEFAULT_TRAIN = {"batch": 128, "bptt": 48, "tokens": 150_000_000, "lr": 3e-3, "min_lr_ratio": 0.05,
                 "warmup": 1000, "clip": 1.0, "weight_decay": 0.01, "eval_every": 1000, "log_every": 50,
                 "seed": 1234, "valid": ["tatoeba", "wikitext"], "chunk": 1024, "eval_device": "cpu"}


def device_of(name: str | None) -> torch.device:
    if name:
        return torch.device(name)
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def unigram_bias(mixture: Mixture, vocab_size: int) -> torch.Tensor:
    """Initial output bias = log unigram of the training targets (faster, calmer start)."""
    counts = np.zeros(vocab_size)
    for source, weight in mixture.weights.items():
        counts += weight * np.bincount(np.asarray(mixture.shards[source].tokens), minlength=vocab_size)
    counts[BOS] = 0
    probabilities = (counts + 0.5) / (counts + 0.5).sum()
    return torch.tensor(np.log(probabilities), dtype=torch.float32)


def learning_rate(step: int, total: int, cfg: dict) -> float:
    if step < cfg["warmup"]:
        return cfg["lr"] * (step + 1) / cfg["warmup"]
    progress = min(1.0, (step - cfg["warmup"]) / max(1, total - cfg["warmup"]))
    return cfg["lr"] * (cfg["min_lr_ratio"] + (1 - cfg["min_lr_ratio"]) * 0.5 * (1 + math.cos(math.pi * progress)))


def save(path: Path, model, optimizer, step: int, epoch: int, config: dict, extra: dict) -> None:
    torch.save({"model": model.state_dict(), "optimizer": optimizer.state_dict(), "step": step, "epoch": epoch,
                "arch": model.config(), "config": config, **extra}, path.with_suffix(".tmp"))
    path.with_suffix(".tmp").replace(path)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--data", type=Path, default=DATA)
    parser.add_argument("--device")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--tokens", type=float, help="override train.tokens")
    args = parser.parse_args(argv)

    config = json.loads(args.config.read_text())
    cfg = {**DEFAULT_TRAIN, **config.get("train", {})}
    if args.tokens:
        cfg["tokens"] = int(args.tokens)
    config["train"] = cfg
    out = args.out or RUNS / args.config.stem
    out.mkdir(parents=True, exist_ok=True)
    device = device_of(args.device)
    random.seed(cfg["seed"])
    np.random.seed(cfg["seed"])
    torch.manual_seed(cfg["seed"])

    vocab = Vocabulary.load()
    corpus = json.loads((args.data / "corpus.json").read_text())
    if corpus["vocabulary_sha256"] != vocab.sha256:
        raise SystemExit("training data was built with a different vocabulary")
    weights = config["data"]["weights"]
    mixture = Mixture(args.data, weights, "train", cfg["seed"])
    valid = {name: Shard.load(args.data, name, "valid") for name in cfg["valid"]}
    model = build(config["model"], len(vocab)).to(device)
    share = lexicon_share(args.data, weights)
    extra = {"vocabulary_sha256": vocab.sha256, "langdata_sha256": corpus["langdata_sha256"],
             "unk_lexicon_share": share, "data": {"weights": weights, "corpus": corpus}}

    decay = [p for n, p in model.named_parameters() if not model.no_decay(n)]
    no_decay = [p for n, p in model.named_parameters() if model.no_decay(n)]
    optimizer = torch.optim.AdamW([{"params": decay, "weight_decay": cfg["weight_decay"]},
                                   {"params": no_decay, "weight_decay": 0.0}], lr=cfg["lr"], betas=(0.9, 0.98))
    tokens_per_step = cfg["batch"] * cfg["bptt"]
    total_steps = max(1, int(cfg["tokens"] // tokens_per_step))
    step, epoch, best, skip = 0, 0, float("inf"), 0
    last = out / "last.pt"
    if args.resume and last.exists():
        checkpoint = torch.load(last, map_location=device)
        model.load_state_dict(checkpoint["model"])
        optimizer.load_state_dict(checkpoint["optimizer"])
        step, epoch = checkpoint["step"], checkpoint["epoch"]
        best, skip = checkpoint.get("best", best), checkpoint.get("epoch_batches", 0)
    else:
        with torch.no_grad():
            model.output_bias.copy_(unigram_bias(mixture, len(vocab)).to(device))
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    log = (out / "log.jsonl").open("a")
    print(f"{model.arch}: {model.parameter_count():,} parameters; {total_steps:,} steps of "
          f"{tokens_per_step:,} tokens; epoch = {mixture.epoch_tokens():,} tokens; device {device}; "
          f"<unk> lexicon share {share:.3f}", flush=True)

    model.train()
    started, seen, window_loss, window_tokens = time.time(), 0, 0.0, 0
    while step < total_steps:
        state = None
        batches_this_epoch = 0
        for inputs, targets in mixture.batches(cfg["batch"], cfg["bptt"], epoch):
            batches_this_epoch += 1
            if skip > 0:  # resuming: skip the batches this epoch already trained on
                skip -= 1
                continue
            if step >= total_steps:
                break
            for group in optimizer.param_groups:
                group["lr"] = learning_rate(step, total_steps, cfg)
            x = torch.from_numpy(inputs).to(device)
            y = torch.from_numpy(targets).to(device)
            features, state = model(x, state)
            state = detach(state)
            keep = (y != BOS).reshape(-1)
            count = int(keep.sum())
            loss = cross_entropy_sum(features.reshape(-1, features.shape[-1]), model.output_weight, model.output_bias,
                                     y.reshape(-1), cfg["chunk"], keep) / count
            optimizer.zero_grad(set_to_none=True)
            loss.backward()
            norm = torch.nn.utils.clip_grad_norm_(model.parameters(), cfg["clip"])
            optimizer.step()
            step += 1
            seen += count
            window_loss += loss.item() * count
            window_tokens += count
            if step % cfg["log_every"] == 0:
                elapsed = time.time() - started
                record = {"step": step, "epoch": epoch, "loss": window_loss / window_tokens,
                          "ppl": math.exp(window_loss / window_tokens), "lr": optimizer.param_groups[0]["lr"],
                          "grad_norm": float(norm), "tokens_per_s": seen / elapsed}
                print(json.dumps(record), flush=True)
                log.write(json.dumps(record) + "\n")
                log.flush()
                window_loss, window_tokens = 0.0, 0
            if step % cfg["eval_every"] == 0 or step == total_steps:
                # Validation runs on a CPU copy: MPS recompiles kernels for every new batch
                # shape of the length-sorted sentences, which made one pass take minutes.
                evaluator = copy.deepcopy(model).to(cfg["eval_device"])
                results = {name: evaluate(evaluator, shard, torch.device(cfg["eval_device"])) for name, shard in valid.items()}
                del evaluator
                score = float(np.mean([math.log(r["ppl_word"]) for r in results.values()]))
                record = {"step": step, "valid": results, "score": score}
                print(json.dumps(record), flush=True)
                log.write(json.dumps(record) + "\n")
                log.flush()
                if score < best:
                    best = score
                    save(out / "best.pt", model, optimizer, step, epoch, config, {**extra, "best": best, "valid": results})
                save(last, model, optimizer, step, epoch, config, {**extra, "best": best, "epoch_batches": batches_this_epoch})
        epoch += 1
        if batches_this_epoch == 0:
            break
    save(last, model, optimizer, step, epoch, config, {**extra, "best": best})


if __name__ == "__main__":
    main()
