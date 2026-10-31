"""Architecture registry: build any NSS model from its JSON config."""

from __future__ import annotations

from .base import State, StreamingLM, detach
from .rnn import GRU, LSTM
from .ssm import SSM
from .transformer import Transformer

ARCHITECTURES: dict[str, type[StreamingLM]] = {cls.arch: cls for cls in (LSTM, GRU, Transformer, SSM)}


def build(config: dict, vocab_size: int) -> StreamingLM:
    options = dict(config)
    arch = options.pop("arch")
    if arch not in ARCHITECTURES:
        raise ValueError(f"unknown architecture {arch!r}; choose from {sorted(ARCHITECTURES)}")
    return ARCHITECTURES[arch](vocab_size, **options)


__all__ = ["ARCHITECTURES", "State", "StreamingLM", "build", "detach"]
