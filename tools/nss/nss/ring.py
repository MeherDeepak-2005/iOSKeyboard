"""Rolling ring buffer of per-word model states: the context is read once.

The keyboard sends the decoder the last <= 8 words of the current sentence on every
request. Re-running the model over them each time would repeat the same work per
keystroke and per word. Instead the ring keeps, for the last `capacity` words of the
sentence, the word id and the model state after it (slot = position % capacity; the
oldest slot is overwritten). The state after `<bos>` is the root, computed once.

`sync(context)` finds the longest cached match and steps only the words after it:

* same context (another keystroke in the same word): 0 steps
* one more committed word: 1 step
* backspace into the previous word / an edited last word: 0 or 1 steps
* the 8-word window slid by one word: 1 step (matched against the cached history,
  so the state still includes the words before the window)
* an unrelated context (cursor moved, new field): at most `len(context)` steps

A context shorter than the window starts at the sentence start, so it may only match
from the root. A full window may be a suffix of a longer sentence, so it may match
anywhere in the cached history; with no match it starts from the root, as if the
sentence began at the window. C++ (`ContextRing` in NeuralLanguageModel.hpp) mirrors
this exactly; tests/test_ring.py pins the behaviour.
"""

from __future__ import annotations

from dataclasses import dataclass

import torch

from .models import State, StreamingLM
from .vocab import BOS


def _select(state: State) -> State:
    return tuple(part.detach().clone() for part in state)


@dataclass
class SyncResult:
    state: State
    features: torch.Tensor
    reused: int      # context words served from the ring
    stepped: int     # model steps this sync ran


class ContextRing:
    def __init__(self, model: StreamingLM, capacity: int = 64, window: int = 8):
        if capacity < window:
            raise ValueError("ring capacity must hold at least one context window")
        self.model, self.capacity, self.window = model, capacity, window
        device = next(model.parameters()).device
        features, state = model.step(torch.tensor([BOS], device=device), model.init_state(1, device))
        self.root = (features, _select(state))
        self.ids: list[int | None] = [None] * capacity
        self.slots: list[tuple[torch.Tensor, State] | None] = [None] * capacity
        self.length = 0          # words of the cached sentence history
        self.steps = 0           # total model steps (for tests and telemetry)

    def _oldest(self) -> int:
        return max(1, self.length - self.capacity + 1)

    def _id(self, position: int) -> int:
        return self.ids[(position - 1) % self.capacity]

    def _entry(self, position: int) -> tuple[torch.Tensor, State]:
        return self.root if position == 0 else self.slots[(position - 1) % self.capacity]

    def _match(self, context: list[int]) -> tuple[int, int]:
        """(start, matched): history[start+1 .. start+matched] == context[:matched]."""
        n, oldest = len(context), self._oldest()
        starts = [0] if n < self.window else range(self.length, -1, -1)
        best = (0, 0)
        for start in starts:
            if start + 1 < oldest:          # history after `start` was overwritten
                if start:
                    break
                continue                    # sentence start evicted: only the root is usable
            matched = 0
            while matched < n and start + matched < self.length and self._id(start + matched + 1) == context[matched]:
                matched += 1
            if matched > best[1]:           # most recent start wins ties
                best = (start, matched)
        return best

    def sync(self, context: list[int]) -> SyncResult:
        start, matched = self._match(context)
        position = start + matched
        features, state = self._entry(position)
        self.length = position
        device = features.device
        for word in context[matched:]:
            features, state = self.model.step(torch.tensor([word], device=device), state)
            state = _select(state)
            self.length += 1
            slot = (self.length - 1) % self.capacity
            self.ids[slot], self.slots[slot] = word, (features, state)
            self.steps += 1
        return SyncResult(state, features, matched, len(context) - matched)
