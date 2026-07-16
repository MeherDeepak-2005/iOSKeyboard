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

    def forward_cached(self, x, past_k, past_v):
        """Incremental attention for KV-cache decoding. `x` is the NEW token(s)
        [B, T, d]; `past_k`/`past_v` are the cached keys/values [B, H, P, hd] for the
        P tokens already seen. The new tokens attend over all P+T positions (causal is
        automatic — nothing after them exists yet). Returns the updated hidden state
        plus the appended K/V so the caller threads them to the next step. Math is
        identical to `forward`; only the mask range differs."""
        B, T, d = x.shape
        h = self.n1(x)
        q, k, v = self.qkv(h).split(d, dim=2)
        def heads(t): return t.view(B, T, self.heads, self.hd).transpose(1, 2)
        q, k, v = heads(q), heads(k), heads(v)          # [B, H, T, hd]
        K = torch.cat([past_k, k], dim=2)               # [B, H, P+T, hd]
        V = torch.cat([past_v, v], dim=2)
        Tk = K.shape[2]                                 # = P + T
        # New token t (0..T-1) sits at absolute position P+t and may attend to <= P+t.
        # For the steady-state T=1 step this is all-zeros (attend to everything so far).
        col = torch.arange(Tk)
        row = torch.arange(T) + (Tk - T)
        mask = torch.where(col[None, :] <= row[:, None], 0.0, float("-inf"))
        att = ((q @ K.transpose(-2, -1)) / (self.hd ** 0.5) + mask).softmax(dim=-1)
        o = (att @ V).transpose(1, 2).reshape(B, T, d)
        x = x + self.proj(o)
        x = x + self.ff(self.n2(x))
        return x, K, V


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
        return self.head(self.hidden(tokens))          # [B, maxlen, vocab]

    def hidden(self, tokens):
        """Return normalized transformer states without materializing vocab logits.

        The keyboard export gathers only the positions it needs from these states.
        Training still calls ``forward`` and therefore remains unchanged.
        """
        # No reference to tokens.shape — full fixed buffers, so the trace has no
        # dynamic int-from-shape ops for Core ML to choke on.
        x = self.emb(tokens) + self.pos(self.pos_ids)
        for block in self.blocks:
            x = block(x, self.causal)
        return self.norm(x)                           # [B, maxlen, d]

    def empty_cache(self, batch=1):
        """Per-layer (K, V) buffers with zero length — the starting cache before any
        token has been seen. Shapes match Block.forward_cached's `past_k`/`past_v`."""
        d = self.emb.embedding_dim
        heads = self.blocks[0].heads
        hd = d // heads
        return [(torch.zeros(batch, heads, 0, hd), torch.zeros(batch, heads, 0, hd))
                for _ in self.blocks]

    def forward_cached(self, tokens, cache, start_pos):
        """KV-cache step: encode `tokens` [B, T] placed at absolute positions
        [start_pos, start_pos+T), reusing `cache` (list of per-layer (K, V) for the
        start_pos tokens already seen). Returns (logits [B, T, vocab], new_cache).
        Feeding tokens one at a time with the returned cache reproduces the full
        stateless forward on the same sequence — no left-padding, no re-encode."""
        B, T = tokens.shape
        pos = self.pos_ids[start_pos:start_pos + T]
        x = self.emb(tokens) + self.pos(pos)
        new_cache = []
        for block, (pk, pv) in zip(self.blocks, cache):
            x, k, v = block.forward_cached(x, pk, pv)
            new_cache.append((k, v))
        return self.head(self.norm(x)), new_cache


class KeyboardInferenceModel(nn.Module):
    """Memory-bounded Core ML interface used by the keyboard extension.

    The old export returned [B, 32, vocab] even though candidate scoring needs at
    most a handful of positions and next-word search needs one. This wrapper first
    gathers the requested hidden states and only then applies the tied LM head.

    A single model/function serves both call sites so the 4.7M weights are not
    duplicated in the extension bundle:

      candidate_log_probs [B]       exact sum of selected-token log probabilities
      next_logits          [B, V]    distribution at one requested position

    ``score_mask`` makes unused slots in the fixed K=8 candidate array inert.
    """
    score_slots = 8

    def __init__(self, lm: TinyLM):
        super().__init__()
        self.lm = lm
        self.d = lm.emb.embedding_dim

    def _gather_hidden(self, hidden, positions):
        index = positions.to(torch.int64).unsqueeze(-1).expand(-1, -1, self.d)
        return torch.gather(hidden, dim=1, index=index)

    def forward(self, tokens, score_positions, target_ids, score_mask, next_positions):
        hidden = self.lm.hidden(tokens)

        score_hidden = self._gather_hidden(hidden, score_positions)
        score_logits = self.lm.head(score_hidden)       # [B, K, V], not [B, L, V]
        score_log_probs = F.log_softmax(score_logits, dim=-1)
        selected = torch.gather(
            score_log_probs, dim=2, index=target_ids.to(torch.int64).unsqueeze(-1)
        ).squeeze(-1)
        candidate_log_probs = (selected * score_mask).sum(dim=1)

        next_hidden = self._gather_hidden(hidden, next_positions)
        next_logits = self.lm.head(next_hidden).squeeze(1)  # [B, V]
        return candidate_log_probs, next_logits
