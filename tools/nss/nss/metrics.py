"""Held-out evaluation of a streaming word LM (sentence by sentence, exact).

Reported per set:
  ppl_all    perplexity over every target (words, <unk>, <eos>)
  ppl_word   perplexity of word targets (incl. <unk>) under the decoder's distribution:
             <pad>/<bos>/<eos> masked out, i.e. P(w | context, a word follows)
  top1/top3  next-word accuracy on in-vocabulary targets, <unk> never predicted
  unk_pred   mean predicted P(<unk>) over word positions; unk_rate is the observed share
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import torch

from .data import Shard
from .vocab import BOS, EOS, PAD, UNK

SPECIAL_MASK = (PAD, BOS, EOS)


def sentence_batches(shard: Shard, max_tokens: int = 16384, scored: np.ndarray | None = None):
    """Sentences grouped by length: (inputs [B, L], targets [B, L], score mask [B, L])."""
    offsets = shard.offsets
    lengths = offsets[1:] - offsets[:-1]
    order = np.argsort(lengths, kind="stable")
    tokens = np.asarray(shard.tokens)
    group: list[int] = []
    for index in order:
        width = int(lengths[index]) - 1
        if group and (len(group) + 1) * max(width, int(lengths[group[-1]]) - 1) > max_tokens:
            yield _pack(tokens, offsets, group, scored)
            group = []
        group.append(int(index))
    if group:
        yield _pack(tokens, offsets, group, scored)


def _pack(tokens, offsets, group, scored):
    width = max(int(offsets[i + 1] - offsets[i]) - 1 for i in group)
    inputs = np.full((len(group), width), PAD, np.int64)
    targets = np.full((len(group), width), PAD, np.int64)
    mask = np.zeros((len(group), width), bool)
    for row, i in enumerate(group):
        sentence = tokens[offsets[i]:offsets[i + 1]].astype(np.int64)
        n = len(sentence) - 1
        inputs[row, :n], targets[row, :n] = sentence[:-1], sentence[1:]
        mask[row, :n] = True if scored is None else scored[offsets[i] + 1:offsets[i + 1]]
    return inputs, targets, mask


def word_log_probs(logits: torch.Tensor) -> torch.Tensor:
    """The decoder's distribution: specials other than <unk> removed, renormalized."""
    masked = logits.clone()
    masked[..., list(SPECIAL_MASK)] = float("-inf")
    return torch.log_softmax(masked, -1)


@dataclass
class Totals:
    nll_all: float = 0.0
    count_all: int = 0
    nll_word: float = 0.0
    count_word: int = 0
    top1: int = 0
    top3: int = 0
    count_known: int = 0
    unk_pred: float = 0.0
    unk_seen: int = 0

    def report(self) -> dict:
        return {"ppl_all": math.exp(self.nll_all / max(self.count_all, 1)),
                "ppl_word": math.exp(self.nll_word / max(self.count_word, 1)),
                "top1": self.top1 / max(self.count_known, 1), "top3": self.top3 / max(self.count_known, 1),
                "unk_pred": self.unk_pred / max(self.count_word, 1), "unk_rate": self.unk_seen / max(self.count_word, 1),
                "tokens": self.count_all}


@torch.no_grad()
def evaluate(model, shard: Shard, device, scored: np.ndarray | None = None, max_tokens: int = 16384,
             logits_fn=None) -> dict:
    model.eval()
    totals = Totals()
    for inputs, targets, mask in sentence_batches(shard, max_tokens, scored):
        x = torch.from_numpy(inputs).to(device)
        y = torch.from_numpy(targets).to(device)
        m = torch.from_numpy(mask).to(device)
        features, _ = model(x)
        rows, wanted = features[m], y[m]
        for start in range(0, rows.shape[0], 2048):
            f, t = rows[start:start + 2048], wanted[start:start + 2048]
            logits = (logits_fn or model.logits)(f)
            all_lp = torch.log_softmax(logits, -1)
            totals.nll_all -= all_lp.gather(1, t[:, None]).sum().item()
            totals.count_all += t.numel()
            words = t != EOS
            lp = word_log_probs(logits[words])
            tw = t[words]
            totals.nll_word -= lp.gather(1, tw[:, None]).sum().item()
            totals.count_word += tw.numel()
            totals.unk_pred += lp[:, UNK].exp().sum().item()
            totals.unk_seen += (tw == UNK).sum().item()
            # Rank of each in-vocabulary target among words (<unk> is never suggested):
            # the number of words scored above it. No top-k sort (slow on MPS).
            known = (tw != UNK).float()
            ranked = lp.clone()
            ranked[:, UNK] = float("-inf")
            above = (ranked > ranked.gather(1, tw[:, None])).sum(-1)
            totals.top1 += ((above < 1).float() * known).sum().item()
            totals.top3 += ((above < 3).float() * known).sum().item()
            totals.count_known += int(known.sum().item())
    model.train()
    return totals.report()
