"""Python reference of the runtime neural search space (C++ `NeuralSearchSpace`).

Per context (UpdateLM, when a new word starts): sync the ring buffer, run the output
layer once, and keep the decoder's distribution log P(w | context, a word follows)
(<pad>/<bos>/<eos> masked out). Every keystroke of that word reuses it:

  log_probability(w)  vocabulary word: its log-probability; any other word:
                      log P(<unk>|ctx) + log share + log u(w) - log oov_mass
  arcs(threshold)     vocabulary words above the threshold (Gboard: e^-15), best first:
                      the words the search space expands with their LM weight
  sequence(words)     ExtendLM for a multi-word candidate ("of the"): each later word is
                      scored after stepping the model through the earlier ones, from the
                      cached context state, without touching the ring
"""

from __future__ import annotations

import torch

from .lexicon import Lexicon, UnkPolicy
from .metrics import word_log_probs
from .models import StreamingLM
from .ring import ContextRing
from .vocab import UNK, Vocabulary


def ascii_lower(word: str) -> str:
    return "".join(c.lower() if c.isascii() else c for c in word)


class NeuralSearchSpace:
    def __init__(self, model: StreamingLM, vocab: Vocabulary, lexicon: Lexicon, policy: UnkPolicy,
                 capacity: int = 64, window: int = 8):
        self.model, self.vocab, self.lexicon, self.policy = model.eval(), vocab, lexicon, policy
        self.ring = ContextRing(model, capacity, window)
        self.features = self.state = self.log_probs = None

    def context_ids(self, context: list[str]) -> list[int]:
        """The runtime's context mapping: ASCII lowercase, quotes stripped, bare
        apostrophes skipped, anything outside the vocabulary <unk>."""
        return [self.vocab.id(ascii_lower(word)) for word in context if word.strip("'")]

    @torch.no_grad()
    def update(self, context: list[str]) -> None:
        result = self.ring.sync(self.context_ids(context))
        self.features, self.state = result.features, result.state
        self.log_probs = word_log_probs(self.model.logits(result.features))[0].double()

    def unk_log_probability(self) -> float:
        return float(self.log_probs[UNK])

    def _score(self, word: str, log_probs: torch.Tensor) -> float:
        index = self.vocab.exact(word)
        if index != UNK:
            return float(log_probs[index])
        return float(log_probs[UNK]) + self.policy.log_word_given_unk(self.lexicon.unigram_mass(word))

    def log_probability(self, word: str) -> float:
        return self._score(word, self.log_probs)

    def arcs(self, threshold: float = -15.0) -> list[tuple[str, float]]:
        values = self.log_probs.clone()
        values[:UNK + 1] = float("-inf")
        values[2:4] = float("-inf")
        keep = torch.nonzero(values > threshold).flatten()
        order = keep[torch.argsort(values[keep], descending=True, stable=True)]
        return [(self.vocab.words[i], float(values[i])) for i in order.tolist()]

    @torch.no_grad()
    def sequence(self, words: list[str]) -> float:
        total, features, state, log_probs = 0.0, self.features, self.state, self.log_probs
        device = features.device
        for k, word in enumerate(words):
            total += self._score(word, log_probs)
            if k + 1 < len(words):
                features, state = self.model.step(torch.tensor([self.vocab.id(word)], device=device), state)
                log_probs = word_log_probs(self.model.logits(features))[0].double()
        return total
