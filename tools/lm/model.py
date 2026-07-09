"""TinyLM — the 4-layer decoder-only rescorer (~4.7M params at the defaults).

Explicit attention (not nn.TransformerEncoder) for two reasons:
  1. MPS hangs on TransformerEncoder + float causal mask (nested-tensor path).
  2. A plain module traces to Core ML cleanly — no fused kernels to lower.

Param math:
  emb  6000*256            = 1.54M   (tied with the output head — counted once)
  attn 4*(4*256*256)       = 1.05M
  ffn  4*(2*256*1024)      = 2.10M
  ---------------------------------
                            ~4.7M    -> ~4.7 MB int8
"""

import torch
import torch.nn as nn
import torch.nn.functional as F


class Block(nn.Module):
    def __init__(self, d, heads, ff):
        super().__init__()
        self.heads = heads
        self.hd = d // heads
        self.n1 = nn.LayerNorm(d)
        self.qkv = nn.Linear(d, 3 * d)
        self.proj = nn.Linear(d, d)
        self.n2 = nn.LayerNorm(d)
        self.ff = nn.Sequential(nn.Linear(d, ff), nn.GELU(), nn.Linear(ff, d))

    def forward(self, x, mask):                       # x: [B, L, d]
        B, L, d = x.shape
        h = self.n1(x)
        q, k, v = self.qkv(h).split(d, dim=2)
        def heads(t): return t.view(B, L, self.heads, self.hd).transpose(1, 2)
        q, k, v = heads(q), heads(k), heads(v)         # [B, H, L, hd]
        att = (q @ k.transpose(-2, -1)) / (self.hd ** 0.5) + mask
        att = att.softmax(dim=-1)
        o = (att @ v).transpose(1, 2).reshape(B, L, d)
        x = x + self.proj(o)
        x = x + self.ff(self.n2(x))
        return x


class TinyLM(nn.Module):
    # Fixed sequence length (no shape-derived indexing anywhere in forward) so the
    # graph traces to Core ML without dynamic int ops. 32 tokens covers the
    # keyboard's 8-word context (~24 tokens) plus the candidate. Inputs are always
    # exactly this length — training packs to it, inference left-pads/truncates to it.
    def __init__(self, vocab=6000, d=256, layers=4, heads=4, ff=1024, maxlen=32):
        super().__init__()
        self.maxlen = maxlen
        self.emb = nn.Embedding(vocab, d)
        self.pos = nn.Embedding(maxlen, d)
        self.blocks = nn.ModuleList([Block(d, heads, ff) for _ in range(layers)])
        self.norm = nn.LayerNorm(d)
        self.head = nn.Linear(d, vocab, bias=False)
        self.head.weight = self.emb.weight            # tied embeddings
        # Precomputed positions + causal mask as buffers. Building these at runtime
        # from tokens.shape (arange / full) emits dynamic int-from-shape ops that
        # Core ML can't lower; slicing fixed buffers traces cleanly.
        self.register_buffer("pos_ids", torch.arange(maxlen), persistent=False)
        self.register_buffer("causal",
                             torch.triu(torch.full((maxlen, maxlen), float("-inf")), 1),
                             persistent=False)
        self.apply(self._init)

    @staticmethod
    def _init(m):
        # Small-std init (GPT convention). Without it, tied logits = hidden @ emb.T
        # start at a huge scale (initial CE ~170 instead of ~ln(vocab)), wasting the
        # first hundreds of steps and risking divergence.
        if isinstance(m, nn.Linear):
            nn.init.normal_(m.weight, std=0.02)
            if m.bias is not None:
                nn.init.zeros_(m.bias)
        elif isinstance(m, nn.Embedding):
            nn.init.normal_(m.weight, std=0.02)

    def forward(self, tokens):                        # tokens: [B, maxlen] int
        # No reference to tokens.shape — full fixed buffers, so the trace has no
        # dynamic int-from-shape ops for Core ML to choke on.
        x = self.emb(tokens) + self.pos(self.pos_ids)
        for block in self.blocks:
            x = block(x, self.causal)
        return self.head(self.norm(x))                # [B, maxlen, vocab]
