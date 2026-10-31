"""Sliding-window causal transformer whose state is a rolling key/value buffer.

Each layer attends to at most `window` earlier positions of the same sentence, so the
state is a fixed-size ring of the last `window` keys and values per layer (Mistral's
rolling buffer cache): a new word costs one position, never a re-read of the context.
Rotary positions count from the sentence's `<bos>`, so they stay small and exact.
"""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

from .base import RMSNorm, StreamingLM, SwiGLU


def rotary(x: torch.Tensor, positions: torch.Tensor, base: float = 10000.0) -> torch.Tensor:
    """x [B, H, T, D], positions [B, T]."""
    half = x.shape[-1] // 2
    freqs = base ** (-torch.arange(half, device=x.device, dtype=torch.float32) / half)
    angles = positions.to(torch.float32)[:, None, :, None] * freqs
    cos, sin = angles.cos().to(x.dtype), angles.sin().to(x.dtype)
    a, b = x[..., :half], x[..., half:]
    return torch.cat([a * cos - b * sin, a * sin + b * cos], -1)


class Block(nn.Module):
    def __init__(self, dim: int, heads: int, ffn: int):
        super().__init__()
        self.heads = heads
        self.attention_norm, self.mlp_norm = RMSNorm(dim), RMSNorm(dim)
        self.qkv = nn.Linear(dim, 3 * dim, bias=False)
        self.out = nn.Linear(dim, dim, bias=False)
        self.mlp = SwiGLU(dim, ffn)

    def forward(self, x, positions, mask, cache_k, cache_v):
        B, T, D = x.shape
        q, k, v = self.qkv(self.attention_norm(x)).view(B, T, 3, self.heads, D // self.heads).permute(2, 0, 3, 1, 4)
        q, k = rotary(q, positions), rotary(k, positions)
        keys, values = torch.cat([cache_k, k], 2), torch.cat([cache_v, v], 2)
        attended = F.scaled_dot_product_attention(q, keys, values, attn_mask=mask[:, None])
        x = x + self.out(attended.transpose(1, 2).reshape(B, T, D))
        return x + self.mlp(self.mlp_norm(x)), keys, values


class Transformer(StreamingLM):
    arch = "transformer"

    def __init__(self, vocab_size: int, embed: int = 96, dim: int = 128, layers: int = 4, heads: int = 4,
                 ffn: int = 344, window: int = 32, tied: bool = True, dropout: float = 0.0):
        super().__init__(vocab_size, embed, embed, tied, dropout)
        self.dim, self.layers, self.heads, self.ffn, self.window = dim, layers, heads, ffn, window
        self.up = nn.Linear(embed, dim, bias=False) if dim != embed else nn.Identity()
        self.blocks = nn.ModuleList(Block(dim, heads, ffn) for _ in range(layers))
        self.final_norm = RMSNorm(dim)
        self.down = nn.Linear(dim, embed, bias=False) if dim != embed else nn.Identity()

    def init_state(self, batch, device):
        head = self.dim // self.heads
        empty = torch.zeros(self.layers, batch, self.heads, self.window, head, device=device)
        return (empty, empty.clone(),
                torch.full((batch, self.window), -1, dtype=torch.long, device=device),   # segment per slot
                torch.zeros(batch, self.window, dtype=torch.long, device=device),        # position per slot
                torch.zeros(batch, dtype=torch.long, device=device),                     # current segment
                torch.zeros(batch, dtype=torch.long, device=device))                     # next position

    def sequence(self, x, reset, state):
        cache_k, cache_v, cache_seg, cache_pos, segment, position = state
        B, T, _ = x.shape
        # Segment ids rise at every reset; positions restart from 0 inside each segment.
        seg = segment[:, None] + torch.cumsum(reset.long(), 1)
        steps = torch.arange(T, device=x.device).expand(B, T)
        last_reset = torch.cummax(torch.where(reset, steps, torch.full_like(steps, -1)), 1).values
        pos = torch.where(last_reset >= 0, steps - last_reset, position[:, None] + steps)
        key_seg, key_pos = torch.cat([cache_seg, seg], 1), torch.cat([cache_pos, pos], 1)
        mask = ((key_seg[:, None, :] == seg[:, :, None]) & (key_pos[:, None, :] <= pos[:, :, None])
                & (pos[:, :, None] - key_pos[:, None, :] < self.window))
        mask[..., :self.window] &= cache_seg[:, None, :] >= 0
        hidden = self.up(x)
        keys, values = [], []
        for index, block in enumerate(self.blocks):
            hidden, k, v = block(hidden, pos, mask, cache_k[index], cache_v[index])
            keys.append(k[:, :, -self.window:])
            values.append(v[:, :, -self.window:])
        state = (torch.stack(keys), torch.stack(values), key_seg[:, -self.window:], key_pos[:, -self.window:],
                 seg[:, -1], pos[:, -1] + 1)
        return self.down(self.final_norm(hidden)), state

    def config(self):
        return {"arch": self.arch, "embed": self.embed, "dim": self.dim, "layers": self.layers,
                "heads": self.heads, "ffn": self.ffn, "window": self.window, "tied": self.tied}
