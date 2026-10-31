"""Recurrent NSS models: LSTM (optionally CIFG and projected) and GRU.

The NSS reference is Gboard's: one CIFG-LSTM layer, 96-wide embedding, 670 cells.
CIFG couples the input gate to the forget gate (i = 1 - f), saving a quarter of the
gate weights. A projection (LSTMP) maps the 670 cells to the 96-wide recurrent and
output vector, which is what lets the output layer share the input embedding.

Weights are stored the way the C++ runtime reads them: one gate matrix
[gates * hidden, input + recurrent] split here into its input and recurrent halves,
gate order (f, g, o) for CIFG and (i, f, g, o) for LSTM, (r, z, n) for GRU.
"""

from __future__ import annotations

import math

import torch
from torch import nn
from torch.nn import functional as F

from .base import State, StreamingLM, keep_mask


class LSTM(StreamingLM):
    arch = "lstm"

    def __init__(self, vocab_size: int, embed: int = 96, hidden: int = 670, proj: int | None = 96,
                 cifg: bool = True, layers: int = 1, tied: bool = True, dropout: float = 0.0):
        super().__init__(vocab_size, embed, proj or hidden, tied, dropout)
        self.hidden, self.proj, self.cifg, self.layers = hidden, proj, cifg, layers
        self.out_dim = proj or hidden
        gates = 3 if cifg else 4
        bound = 1 / math.sqrt(hidden)
        self.w_input = nn.ParameterList()
        self.w_recurrent = nn.ParameterList()
        self.bias = nn.ParameterList()
        self.w_proj = nn.ParameterList()
        for layer in range(layers):
            width = embed if layer == 0 else self.out_dim
            self.w_input.append(nn.Parameter(torch.empty(gates * hidden, width).uniform_(-bound, bound)))
            self.w_recurrent.append(nn.Parameter(torch.empty(gates * hidden, self.out_dim).uniform_(-bound, bound)))
            bias = torch.zeros(gates * hidden)
            forget = 0 if cifg else 1
            bias[forget * hidden:(forget + 1) * hidden] = 1.0
            self.bias.append(nn.Parameter(bias))
            if proj:
                self.w_proj.append(nn.Parameter(torch.empty(proj, hidden).uniform_(-bound, bound)))

    def init_state(self, batch, device):
        return (torch.zeros(self.layers, batch, self.out_dim, device=device),
                torch.zeros(self.layers, batch, self.hidden, device=device))

    def cell(self, layer: int, projected: torch.Tensor, h: torch.Tensor, c: torch.Tensor):
        """projected: input contribution plus bias [B, gates*hidden]."""
        gates = projected + F.linear(h, self.w_recurrent[layer])
        if self.cifg:
            f, g, o = gates.chunk(3, -1)
            f = torch.sigmoid(f)
            c = f * c + (1 - f) * torch.tanh(g)
        else:
            i, f, g, o = gates.chunk(4, -1)
            c = torch.sigmoid(f) * c + torch.sigmoid(i) * torch.tanh(g)
        m = torch.sigmoid(o) * torch.tanh(c)
        h = F.linear(m, self.w_proj[layer]) if self.proj else m
        return h, c

    def sequence(self, x, reset, state):
        h_all, c_all = state
        hs, cs = list(h_all.unbind(0)), list(c_all.unbind(0))
        layer_input = x
        for layer in range(self.layers):
            projected = F.linear(layer_input, self.w_input[layer], self.bias[layer])
            h, c = hs[layer], cs[layer]
            outputs = []
            for t in range(x.shape[1]):
                keep = keep_mask(reset[:, t], x.dtype)
                h, c = self.cell(layer, projected[:, t], h * keep, c * keep)
                outputs.append(h)
            hs[layer], cs[layer] = h, c
            layer_input = torch.stack(outputs, 1)
        return layer_input, (torch.stack(hs), torch.stack(cs))

    def config(self):
        return {"arch": self.arch, "embed": self.embed, "hidden": self.hidden, "proj": self.proj,
                "cifg": self.cifg, "layers": self.layers, "tied": self.tied}


class GRU(StreamingLM):
    arch = "gru"

    def __init__(self, vocab_size: int, embed: int = 96, hidden: int = 512, proj: int | None = 96,
                 layers: int = 1, tied: bool = True, dropout: float = 0.0):
        super().__init__(vocab_size, embed, proj or hidden, tied, dropout)
        self.hidden, self.proj, self.layers = hidden, proj, layers
        bound = 1 / math.sqrt(hidden)
        self.w_input, self.w_recurrent = nn.ParameterList(), nn.ParameterList()
        self.b_input, self.b_recurrent = nn.ParameterList(), nn.ParameterList()
        self.w_proj = nn.ParameterList()
        for layer in range(layers):
            width = embed if layer == 0 else hidden
            self.w_input.append(nn.Parameter(torch.empty(3 * hidden, width).uniform_(-bound, bound)))
            self.w_recurrent.append(nn.Parameter(torch.empty(3 * hidden, hidden).uniform_(-bound, bound)))
            self.b_input.append(nn.Parameter(torch.zeros(3 * hidden)))
            self.b_recurrent.append(nn.Parameter(torch.zeros(3 * hidden)))
        if proj:
            self.w_proj.append(nn.Parameter(torch.empty(proj, hidden).uniform_(-bound, bound)))

    def init_state(self, batch, device):
        return (torch.zeros(self.layers, batch, self.hidden, device=device),)

    def sequence(self, x, reset, state):
        hs = list(state[0].unbind(0))
        layer_input = x
        for layer in range(self.layers):
            gx = F.linear(layer_input, self.w_input[layer], self.b_input[layer])
            h = hs[layer]
            outputs = []
            for t in range(x.shape[1]):
                h = h * keep_mask(reset[:, t], x.dtype)
                gh = F.linear(h, self.w_recurrent[layer], self.b_recurrent[layer])
                xr, xz, xn = gx[:, t].chunk(3, -1)
                hr, hz, hn = gh.chunk(3, -1)
                r, z = torch.sigmoid(xr + hr), torch.sigmoid(xz + hz)
                h = (1 - z) * torch.tanh(xn + r * hn) + z * h
                outputs.append(h)
            hs[layer] = h
            layer_input = torch.stack(outputs, 1)
        features = F.linear(layer_input, self.w_proj[0]) if self.proj else layer_input
        return features, (torch.stack(hs),)

    def config(self):
        return {"arch": self.arch, "embed": self.embed, "hidden": self.hidden, "proj": self.proj,
                "layers": self.layers, "tied": self.tied}
