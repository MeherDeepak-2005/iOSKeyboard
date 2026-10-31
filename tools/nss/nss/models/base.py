"""The streaming word-LM contract every NSS architecture implements.

A model maps word ids to features, and `logits` maps features to the vocabulary
(optionally tied to the input embedding). The recurrent state is explicit, so the
runtime can keep one state per committed word in a ring buffer and never re-read
the context: `forward(tokens, state)` over a chunk equals `step` threaded token by
token. A `<bos>` input clears the state before it is read, so one stream can pack
many sentences (training) and a new sentence never sees the previous one (runtime).
"""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

from ..vocab import BOS

State = tuple[torch.Tensor, ...]


class StreamingLM(nn.Module):
    arch = "base"

    def __init__(self, vocab_size: int, embed: int, features: int, tied: bool = True, dropout: float = 0.0):
        super().__init__()
        if tied and features != embed:
            raise ValueError(f"tied embeddings need features == embed ({features} != {embed})")
        self.vocab_size, self.embed, self.features, self.tied = vocab_size, embed, features, tied
        self.embedding = nn.Embedding(vocab_size, embed)
        nn.init.uniform_(self.embedding.weight, -0.1, 0.1)
        self.output = None if tied else nn.Parameter(torch.empty(vocab_size, features).uniform_(-0.1, 0.1))
        self.output_bias = nn.Parameter(torch.zeros(vocab_size))
        self.dropout = nn.Dropout(dropout)

    @property
    def output_weight(self) -> torch.Tensor:
        return self.embedding.weight if self.tied else self.output

    def logits(self, features: torch.Tensor) -> torch.Tensor:
        return F.linear(features, self.output_weight, self.output_bias)

    def forward(self, tokens: torch.Tensor, state: State | None = None) -> tuple[torch.Tensor, State]:
        """tokens [B, T] -> features [B, T, features], state after the last token."""
        if state is None:
            state = self.init_state(tokens.shape[0], tokens.device)
        features, state = self.sequence(self.dropout(self.embedding(tokens)), tokens == BOS, state)
        return self.dropout(features), state

    @torch.no_grad()
    def step(self, token: torch.Tensor, state: State | None = None) -> tuple[torch.Tensor, State]:
        """One token per row: token [B] -> features [B, features]."""
        features, state = self.forward(token[:, None], state)
        return features[:, 0], state

    def init_state(self, batch: int, device: torch.device | str) -> State:
        raise NotImplementedError

    def sequence(self, x: torch.Tensor, reset: torch.Tensor, state: State) -> tuple[torch.Tensor, State]:
        """x [B, T, embed]; reset [B, T] clears the state before position t is read."""
        raise NotImplementedError

    def config(self) -> dict:
        raise NotImplementedError

    def no_decay(self, name: str) -> bool:
        return name.endswith("bias") or "norm" in name

    def parameter_count(self) -> int:
        return sum(p.numel() for p in self.parameters())


def detach(state: State) -> State:
    return tuple(part.detach() for part in state)


def keep_mask(reset: torch.Tensor, dtype: torch.dtype) -> torch.Tensor:
    """[B] reset flags -> [B, 1] multiplier that zeroes reset rows."""
    return (~reset).to(dtype).unsqueeze(-1)


class RMSNorm(nn.Module):
    def __init__(self, dim: int, eps: float = 1e-6):
        super().__init__()
        self.eps = eps
        self.weight = nn.Parameter(torch.ones(dim))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + self.eps) * self.weight


class SwiGLU(nn.Module):
    def __init__(self, dim: int, hidden: int):
        super().__init__()
        self.gate = nn.Linear(dim, 2 * hidden, bias=False)
        self.down = nn.Linear(hidden, dim, bias=False)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        gate, value = self.gate(x).chunk(2, -1)
        return self.down(F.silu(gate) * value)
