"""Batches for streaming training: B parallel streams of shuffled sentences.

Each epoch draws sentences from every source by its mixture weight (2.5 = every
sentence twice plus a random half), shuffles them, concatenates them, and cuts the
result into B streams at sentence starts. Batches are consecutive [B, T] windows, so
a sentence longer than T continues in the next batch with the carried (detached)
state, and `<bos>` resets the state inside a window. Targets that are `<bos>` (the
deterministic step from one sentence to the next) are masked out of the loss.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import numpy as np

from .vocab import BOS


@dataclass
class Shard:
    tokens: np.ndarray
    offsets: np.ndarray

    @classmethod
    def load(cls, data: Path, source: str, split: str) -> "Shard":
        return cls(np.load(data / f"{source}.{split}.tokens.npy", mmap_mode="r"),
                   np.load(data / f"{source}.{split}.offsets.npy"))

    @property
    def sentences(self) -> int:
        return len(self.offsets) - 1

    @property
    def size(self) -> int:
        return int(self.offsets[-1])


def gather(shard: Shard, indices: np.ndarray, out: np.ndarray, at: int) -> int:
    """Copy sentences `indices` of `shard` into `out` from `at`; returns the new end."""
    block = 1 << 16
    for first in range(0, len(indices), block):
        chosen = indices[first:first + block]
        starts, ends = shard.offsets[chosen], shard.offsets[chosen + 1]
        lengths = ends - starts
        total = int(lengths.sum())
        # positions = start of each sentence repeated, plus the offset inside it
        within = np.arange(total) - np.repeat(np.cumsum(lengths) - lengths, lengths)
        out[at:at + total] = shard.tokens[np.repeat(starts, lengths) + within]
        at += total
    return at


def streams(sequence: np.ndarray, batch: int) -> np.ndarray:
    """Cut a token sequence into `batch` equal rows that each start at a `<bos>`."""
    bos = np.flatnonzero(sequence == BOS)
    targets = np.arange(batch) * (len(sequence) // batch)
    cuts = bos[np.minimum(np.searchsorted(bos, targets), len(bos) - 1)]
    ends = np.append(cuts[1:], len(sequence))
    length = int((ends - cuts).min())
    return np.stack([sequence[cut:cut + length] for cut in cuts])


class Mixture:
    def __init__(self, data: Path, weights: dict[str, float], split: str = "train", seed: int = 0):
        self.shards = {source: Shard.load(data, source, split) for source in weights}
        self.weights, self.seed = weights, seed

    def epoch_tokens(self) -> int:
        return int(sum(self.shards[s].size * w for s, w in self.weights.items()))

    def sequence(self, epoch: int) -> np.ndarray:
        rng = np.random.default_rng((self.seed, epoch))
        picks = []
        for source, weight in self.weights.items():
            shard = self.shards[source]
            whole, fraction = divmod(weight, 1.0)
            chosen = [np.arange(shard.sentences)] * int(whole)
            chosen.append(rng.choice(shard.sentences, int(round(fraction * shard.sentences)), replace=False))
            picks.append((shard, np.concatenate(chosen)))
        # Shuffle across sources: interleave by a random key per sentence.
        keys = [rng.random(len(indices)) for _, indices in picks]
        owner = np.concatenate([np.full(len(k), i) for i, k in enumerate(keys)])
        order = np.argsort(np.concatenate(keys), kind="stable")
        sizes = sum(int((shard.offsets[idx + 1] - shard.offsets[idx]).sum()) for shard, idx in picks)
        out = np.empty(sizes, np.uint16)
        at = 0
        # Gather runs of consecutive same-source sentences in shuffled order.
        flat = np.concatenate([idx for _, idx in picks])
        bounds = np.flatnonzero(np.diff(owner[order])) + 1
        for run in np.split(order, bounds):
            shard = picks[owner[run[0]]][0]
            at = gather(shard, flat[run], out, at)
        return out

    def batches(self, batch: int, bptt: int, epoch: int) -> Iterator[tuple[np.ndarray, np.ndarray]]:
        rows = streams(self.sequence(epoch), batch)
        for start in range(0, rows.shape[1] - 1 - bptt + 1, bptt):
            yield rows[:, start:start + bptt].astype(np.int64), rows[:, start + 1:start + bptt + 1].astype(np.int64)


def evaluation_rows(shard: Shard, batch: int) -> np.ndarray:
    """Every sentence of a held-out shard, in order, as `batch` rows starting at `<bos>`
    (the tail that does not fill a row is dropped)."""
    return streams(np.asarray(shard.tokens), batch)


def lexicon_share(data: Path, weights: dict[str, float]) -> float:
    """Share of <unk> training tokens that are lexicon words, under the mixture weights."""
    sources = json.loads((data / "corpus.json").read_text())["sources"]
    unk = sum(sources[s]["splits"]["train"]["unk"] * w for s, w in weights.items())
    lexical = sum(sources[s]["splits"]["train"]["unk_lexicon"] * w for s, w in weights.items())
    return lexical / unk
