"""Keyboard language-model definitions used by training and Core ML export.

``TinyLM`` is the legacy 4-layer decoder (~4.7M parameters). The production
exporter also understands ``KeyboardStudentLM``, the 6-layer/384-wide model
from ``qwen_lm_distil`` (10,601,472 unique parameters). Keeping both loaders in
one module lets old checkpoints remain reproducible while the keyboard ships the
larger model without an unsafe state-dict rename.

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

from dataclasses import dataclass

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
        col = torch.arange(Tk, device=x.device)
        row = torch.arange(T, device=x.device) + (Tk - T)
        mask = torch.where(
            col[None, :] <= row[:, None],
            torch.zeros((), device=x.device, dtype=x.dtype),
            torch.full((), float("-inf"), device=x.device, dtype=x.dtype),
        )
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
        return [(self.emb.weight.new_zeros(batch, heads, 0, hd),
                 self.emb.weight.new_zeros(batch, heads, 0, hd))
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


@dataclass(frozen=True)
class StudentModelConfig:
    vocab_size: int = 6000
    d_model: int = 384
    layers: int = 6
    heads: int = 6
    ffn_dim: int = 1024
    max_length: int = 32
    dropout: float = 0.05

    @classmethod
    def from_dict(cls, value):
        allowed = cls.__dataclass_fields__.keys()
        return cls(**{key: value[key] for key in allowed if key in value})


class StudentDecoderBlock(nn.Module):
    """State-dict-compatible block for the supplied 10.6M checkpoint."""

    def __init__(self, config):
        super().__init__()
        width = config.d_model
        if width % config.heads:
            raise ValueError("d_model must be divisible by heads")
        self.heads = config.heads
        self.head_dim = width // config.heads
        self.norm1 = nn.LayerNorm(width)
        self.qkv = nn.Linear(width, 3 * width)
        self.proj = nn.Linear(width, width)
        self.norm2 = nn.LayerNorm(width)
        self.ff1 = nn.Linear(width, config.ffn_dim)
        self.ff2 = nn.Linear(config.ffn_dim, width)
        self.dropout = nn.Dropout(config.dropout)

    def forward(self, x, causal):
        batch, length, width = x.shape
        hidden = self.norm1(x)
        q, k, v = self.qkv(hidden).split(width, dim=-1)

        def split_heads(tensor):
            return tensor.view(batch, length, self.heads, self.head_dim).transpose(1, 2)

        q, k, v = split_heads(q), split_heads(k), split_heads(v)
        attention = (q @ k.transpose(-2, -1)) / (self.head_dim ** 0.5)
        attention = (attention + causal).softmax(dim=-1)
        out = (attention @ v).transpose(1, 2).reshape(batch, length, width)
        x = x + self.dropout(self.proj(out))
        feed_forward = self.ff2(F.gelu(self.ff1(self.norm2(x)), approximate="tanh"))
        return x + self.dropout(feed_forward)

    def forward_cached(self, x, past_k, past_v):
        """Incremental equivalent of ``forward`` for one or more new tokens."""
        batch, length, width = x.shape
        hidden = self.norm1(x)
        q, k, v = self.qkv(hidden).split(width, dim=-1)

        def split_heads(tensor):
            return tensor.view(batch, length, self.heads, self.head_dim).transpose(1, 2)

        q, k, v = split_heads(q), split_heads(k), split_heads(v)
        keys = torch.cat((past_k, k), dim=2)
        values = torch.cat((past_v, v), dim=2)
        key_length = keys.shape[2]
        columns = torch.arange(key_length, device=x.device)
        rows = torch.arange(length, device=x.device) + key_length - length
        causal = torch.where(
            columns[None, :] <= rows[:, None],
            torch.zeros((), device=x.device, dtype=x.dtype),
            torch.full((), float("-inf"), device=x.device, dtype=x.dtype),
        )
        attention = ((q @ keys.transpose(-2, -1)) / (self.head_dim ** 0.5) + causal)
        attention = attention.softmax(dim=-1)
        out = (attention @ values).transpose(1, 2).reshape(batch, length, width)
        x = x + self.dropout(self.proj(out))
        feed_forward = self.ff2(F.gelu(self.ff1(self.norm2(x)), approximate="tanh"))
        return x + self.dropout(feed_forward), keys, values


class KeyboardStudentLM(nn.Module):
    """The supplied 6-layer English keyboard student, independent of train stage."""

    def __init__(self, config):
        super().__init__()
        self.config = config
        self.maxlen = config.max_length
        self.embedding = nn.Embedding(config.vocab_size, config.d_model)
        self.position = nn.Embedding(config.max_length, config.d_model)
        self.blocks = nn.ModuleList([
            StudentDecoderBlock(config) for _ in range(config.layers)
        ])
        self.norm = nn.LayerNorm(config.d_model)
        self.head = nn.Linear(config.d_model, config.vocab_size, bias=False)
        self.head.weight = self.embedding.weight
        self.register_buffer(
            "position_ids", torch.arange(config.max_length), persistent=False
        )
        self.register_buffer(
            "causal",
            torch.triu(torch.full((config.max_length, config.max_length), float("-inf")), 1),
            persistent=False,
        )
        self.apply(self._initialize)

    @staticmethod
    def _initialize(module):
        if isinstance(module, (nn.Linear, nn.Embedding)):
            nn.init.normal_(module.weight, std=0.02)
            if getattr(module, "bias", None) is not None:
                nn.init.zeros_(module.bias)

    def hidden(self, tokens):
        x = self.embedding(tokens) + self.position(self.position_ids)
        for block in self.blocks:
            x = block(x, self.causal)
        return self.norm(x)

    def forward(self, tokens):
        return self.head(self.hidden(tokens))

    def empty_cache(self, batch=1):
        head_dim = self.config.d_model // self.config.heads
        return [
            (
                self.embedding.weight.new_zeros(batch, self.config.heads, 0, head_dim),
                self.embedding.weight.new_zeros(batch, self.config.heads, 0, head_dim),
            )
            for _ in self.blocks
        ]

    def forward_cached(self, tokens, cache, start_pos):
        """Encode only a continuation while reusing the immutable context cache.

        The keyboard can compute a context once between words and branch this state
        across a packed candidate-continuation graph. Tier selection and cache
        ownership stay outside this model so one word session never changes model.
        """
        _, length = tokens.shape
        positions = self.position_ids[start_pos:start_pos + length]
        hidden = self.embedding(tokens) + self.position(positions)
        updated = []
        for block, (past_k, past_v) in zip(self.blocks, cache):
            hidden, keys, values = block.forward_cached(hidden, past_k, past_v)
            updated.append((keys, values))
        return self.head(self.norm(hidden)), updated


@dataclass(frozen=True)
class GRUModelConfig:
    """Streaming GRU LM — the in-loop search-prior challenger (roadmap Plan 3).

    Unlike the transformers above, the GRU carries a fixed-size recurrent state, so
    scoring one more character costs O(1) and needs no growing KV-cache. That is the
    whole point: the keyboard decoder can thread this state through a packed
    prefix-continuation graph and score partial paths at every trie depth cheaply.
    d_model == hidden keeps the output head tied to the embedding (one weight matrix).
    """
    vocab_size: int = 6000
    d_model: int = 256
    hidden: int = 256
    layers: int = 2
    dropout: float = 0.1
    max_length: int = 32          # kept only for packing/eval parity with the transformer

    @classmethod
    def from_dict(cls, value):
        allowed = cls.__dataclass_fields__.keys()
        return cls(**{key: value[key] for key in allowed if key in value})


class KeyboardGRULM(nn.Module):
    """~2.3M-param streaming GRU language model over the shared 6k SentencePiece vocab.

    ``forward`` is used for training/eval (packed [B, L] sequences, next-token loss).
    ``forward_step`` is the deployment interface: one token in, one state threaded out,
    reproducing ``forward`` on the same sequence EXACTLY (guaranteed by the recurrence
    and verified in test_gru_model.py). Nothing here references ``tokens.shape`` for a
    dynamic int, so a single-step function traces cleanly to a Core ML stateful model.
    """

    def __init__(self, config):
        super().__init__()
        self.config = config
        self.maxlen = config.max_length
        self.embedding = nn.Embedding(config.vocab_size, config.d_model)
        self.gru = nn.GRU(
            config.d_model, config.hidden, config.layers,
            batch_first=True, dropout=config.dropout if config.layers > 1 else 0.0,
        )
        self.norm = nn.LayerNorm(config.hidden)
        self.head = nn.Linear(config.hidden, config.vocab_size, bias=False)
        if config.hidden == config.d_model:
            self.head.weight = self.embedding.weight        # tied — one matrix, not two
        self.apply(self._initialize)

    @staticmethod
    def _initialize(module):
        # nn.GRU seeds its own recurrent weights; only touch the embedding/head here so
        # the tied logits don't start at the huge scale untied normal init would give.
        if isinstance(module, nn.Embedding):
            nn.init.normal_(module.weight, std=0.02)
        elif isinstance(module, nn.Linear):
            nn.init.normal_(module.weight, std=0.02)
            if getattr(module, "bias", None) is not None:
                nn.init.zeros_(module.bias)

    def hidden_states(self, tokens, state=None):
        outputs, state = self.gru(self.embedding(tokens), state)   # [B, L, hidden]
        return self.norm(outputs), state                           # LayerNorm is per-position

    def forward(self, tokens):
        states, _ = self.hidden_states(tokens)
        return self.head(states)                                   # [B, L, vocab]

    def empty_state(self, batch=1):
        return self.embedding.weight.new_zeros(self.config.layers, batch, self.config.hidden)

    def forward_step(self, token, state):
        """One streaming step. ``token`` is [B] or [B, 1]; ``state`` is
        [layers, B, hidden] (or None to start). Returns (logits [B, vocab], new_state).
        Threading the returned state token-by-token reproduces ``forward`` on the whole
        sequence — the O(1)-per-token property that makes this an in-loop search prior."""
        if token.dim() == 1:
            token = token.unsqueeze(1)
        states, new_state = self.hidden_states(token, state)       # [B, 1, hidden]
        return self.head(states[:, -1, :]), new_state              # [B, vocab]


class SmoothLinear(nn.Linear):
    """Inference-only linear with an exactly compensating input-channel scale."""

    def __init__(self, source, scale):
        super().__init__(
            source.in_features,
            source.out_features,
            bias=source.bias is not None,
            device=source.weight.device,
            dtype=source.weight.dtype,
        )
        with torch.no_grad():
            self.weight.copy_(source.weight * scale.unsqueeze(0))
            if source.bias is not None:
                self.bias.copy_(source.bias)
        self.weight.requires_grad_(source.weight.requires_grad)
        if self.bias is not None:
            self.bias.requires_grad_(source.bias.requires_grad)
        self.register_buffer("inverse_input_scale", scale.reciprocal())

    def forward(self, inputs):
        return F.linear(inputs * self.inverse_input_scale, self.weight, self.bias)


def apply_smooth_quant(model, input_absmax, alpha=0.5):
    """Balance transformer activations and weight columns without changing outputs.

    ``input_absmax`` maps module names to per-input-channel calibration maxima.
    The tied vocabulary head is deliberately excluded so its embedding matrix is
    neither altered nor duplicated in the exported package.
    """
    if not 0 <= alpha <= 1:
        raise ValueError("SmoothQuant alpha must be between 0 and 1")

    summaries = {}
    modules = list(model.named_modules())
    for name, module in modules:
        if not name or name == "head" or not isinstance(module, nn.Linear):
            continue
        activation = input_absmax.get(name)
        if activation is None or activation.numel() != module.in_features:
            raise ValueError(f"missing SmoothQuant calibration for {name}")
        activation = activation.to(device=module.weight.device, dtype=module.weight.dtype)
        weight = module.weight.detach().abs().amax(dim=0)
        scale = activation.clamp_min(1e-5).pow(alpha) / weight.clamp_min(1e-5).pow(1 - alpha)
        scale = scale.clamp(1e-4, 1e4)
        parent_name, _, child_name = name.rpartition(".")
        parent = model.get_submodule(parent_name) if parent_name else model
        setattr(parent, child_name, SmoothLinear(module, scale))
        summaries[name] = {
            "minimum": float(scale.min()),
            "maximum": float(scale.max()),
        }
    return summaries


def count_parameters(model):
    """Count unique trainable parameters; tied embedding/head weights count once."""
    return sum(parameter.numel() for parameter in model.parameters())


def load_inference_checkpoint(path):
    """Load either the legacy TinyLM checkpoint or the supplied 10.6M format."""
    try:
        checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:  # torch < 2.6 has no weights_only argument
        checkpoint = torch.load(path, map_location="cpu")

    if checkpoint.get("model_type") == "gru":
        config = GRUModelConfig.from_dict(checkpoint["model_config"])
        model = KeyboardGRULM(config)
    elif "model_config" in checkpoint:
        config = StudentModelConfig.from_dict(checkpoint["model_config"])
        model = KeyboardStudentLM(config)
    else:
        model = TinyLM(vocab=checkpoint["vocab"])
    model.load_state_dict(checkpoint["model"])
    return model.eval(), checkpoint


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

    def __init__(self, lm):
        super().__init__()
        self.lm = lm
        embedding = lm.emb if hasattr(lm, "emb") else lm.embedding
        self.d = embedding.embedding_dim

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
