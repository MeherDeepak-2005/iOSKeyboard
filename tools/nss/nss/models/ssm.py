"""Gated diagonal linear recurrence (a selective SSM in the minGRU/LRU family).

Per layer: h_t = a_t * h_{t-1} + (1 - a_t) * v_t with an input-dependent decay
a_t = sigmoid(W_a u_t + b_a), output W_o(h_t * silu(W_g u_t)), then a SwiGLU block.
The recurrence is elementwise, so the state is one vector per layer and a step is a
few matrix-vector products; `<bos>` forces a_t = 0, which clears the state.
"""

from __future__ import annotations

import torch
from torch import nn
from torch.nn import functional as F

from .base import RMSNorm, StreamingLM, SwiGLU


class Mixer(nn.Module):
    def __init__(self, dim: int, state: int, ffn: int):
        super().__init__()
        self.norm, self.mlp_norm = RMSNorm(dim), RMSNorm(dim)
        self.decay = nn.Linear(dim, state)
        self.value = nn.Linear(dim, state, bias=False)
        self.gate = nn.Linear(dim, state, bias=False)
        self.out = nn.Linear(state, dim, bias=False)
        self.mlp = SwiGLU(dim, ffn)
        # Start with long memories: decays spread over ~0.73..0.98.
        nn.init.constant_(self.decay.weight, 0.0)
        with torch.no_grad():
            self.decay.bias.copy_(torch.linspace(1.0, 4.0, state))

    def forward(self, x, reset, h):
        u = self.norm(x)
        a = torch.sigmoid(self.decay(u)).masked_fill(reset[..., None], 0.0)
        drive = (1 - a) * self.value(u)
        states = []
        for t in range(x.shape[1]):
            h = a[:, t] * h + drive[:, t]
            states.append(h)
        y = self.out(torch.stack(states, 1) * F.silu(self.gate(u)))
        x = x + y
        return x + self.mlp(self.mlp_norm(x)), h


class SSM(StreamingLM):
    arch = "ssm"

    def __init__(self, vocab_size: int, embed: int = 96, dim: int = 128, state: int = 256, layers: int = 4,
                 ffn: int = 256, tied: bool = True, dropout: float = 0.0):
        super().__init__(vocab_size, embed, embed, tied, dropout)
        self.dim, self.state_size, self.layers, self.ffn = dim, state, layers, ffn
        self.up = nn.Linear(embed, dim, bias=False) if dim != embed else nn.Identity()
        self.mixers = nn.ModuleList(Mixer(dim, state, ffn) for _ in range(layers))
        self.final_norm = RMSNorm(dim)
        self.down = nn.Linear(dim, embed, bias=False) if dim != embed else nn.Identity()

    def init_state(self, batch, device):
        return (torch.zeros(self.layers, batch, self.state_size, device=device),)

    def sequence(self, x, reset, state):
        hidden, finals = self.up(x), []
        for index, mixer in enumerate(self.mixers):
            hidden, h = mixer(hidden, reset, state[0][index])
            finals.append(h)
        return self.down(self.final_norm(hidden)), (torch.stack(finals),)

    def config(self):
        return {"arch": self.arch, "embed": self.embed, "dim": self.dim, "state": self.state_size,
                "layers": self.layers, "ffn": self.ffn, "tied": self.tied}
