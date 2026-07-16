#!/usr/bin/env python3
"""Interactive next-word prediction probe — Python twins of the two production
next-word paths in KeyboardEngine.nextWords (Keyboardengine.swift):

  n-gram   NgramScorer.nextWords    — trigram->bigram->top-unigram backoff over
                                       langdata.bin's corpus counts (no user model
                                       on the Python side, so this is the
                                       fresh-install answer).
  neural   NeuralScorer.predictWords — trie-constrained beam search over the
                                       pre-trained TinyLM's subword pieces: every
                                       partial expansion must stay a valid trie
                                       prefix, and a candidate only scores once it
                                       completes a real word (piece boundary).

Type a context (space-separated words, oldest→newest) and see both models' top-8
next-word guesses side by side with their scores. Empty line or Ctrl-D to quit.

Usage:
  conda activate ml
  python next_words_probe.py                 # interactive
  python next_words_probe.py "i am going"    # one-shot
"""

import heapq
import math
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import sentencepiece as sspm
import torch

from eval_harness import LangData, Trie, LANGDATA

PAD = 3
BEAM_WIDTH = 8
MAX_PIECES = 4
LIMIT = 8
TOPK_PER_STEP = 64


def is_prefix(root, s):
    node = root
    for ch in s:
        node = node.get(ch)
        if node is None:
            return False
    return True


def is_word(root, s):
    node = root
    for ch in s:
        node = node.get(ch)
        if node is None:
            return False
    return "$" in node


def logaddexp(a, b):
    m = max(a, b)
    if m == -math.inf:
        return m
    return m + math.log(math.exp(a - m) + math.exp(b - m))


class NextWordModels:
    def __init__(self):
        print("loading langdata.bin + trie ...", file=sys.stderr)
        self.ld = LangData(LANGDATA)
        self.trie = Trie(self.ld)          # reuse its char-trie (`.root`) for isPrefix/isWord

        print("loading tokenizer + TinyLM (data/lm.pt) ...", file=sys.stderr)
        self.sp = sspm.SentencePieceProcessor(model_file=str(HERE / "data/spm.model"))
        ckpt = torch.load(HERE / "data/lm.pt", map_location="cpu", weights_only=False)
        from model import TinyLM
        self.nm = TinyLM(vocab=ckpt["vocab"])
        self.nm.load_state_dict(ckpt["model"])
        self.nm.eval()
        self.L = self.nm.maxlen

        vocab_size = self.sp.get_piece_size()
        self.boundary_ids = [i for i in range(vocab_size)
                              if self.sp.id_to_piece(i).startswith("▁")]
        eos = self.sp.piece_to_id("</s>")
        if eos != self.sp.unk_id():
            self.boundary_ids.append(eos)

    # ---- n-gram: mirrors NgramScorer.nextWords (corpus counts only) ----

    def ngram_next_words(self, context, limit=LIMIT):
        ctx = [w.lower() for w in context]
        n = len(ctx)
        if n >= 2:
            a, b = self.ld.ids.get(ctx[-2]), self.ld.ids.get(ctx[-1])
            if a is not None and b is not None:
                hit = self.ld.trigrams(a, b)
                if hit:
                    _, entries = hit
                    ranked = sorted(entries, key=lambda e: -e[1])
                    words = [self.ld.word(w) for w, _ in ranked][:limit]
                    if words:
                        return words
        if n >= 1:
            a = self.ld.ids.get(ctx[-1])
            if a is not None:
                hit = self.ld.bigrams(a)
                if hit:
                    _, entries = hit
                    ranked = sorted(entries, key=lambda e: -e[1])
                    words = [self.ld.word(w) for w, _ in ranked][:limit]
                    if words:
                        return words
        # context-free fallback: top corpus unigrams by raw frequency
        order = sorted(range(self.ld.W), key=lambda i: -self.ld.freqs[i])
        return [self.ld.word(i) for i in order[:limit]]

    # ---- neural: mirrors NeuralScorer.predictWords (trie-constrained beam search) ----

    def _last_token_logprobs(self, rows):
        B, L = len(rows), self.L
        batch = torch.full((B, L), PAD, dtype=torch.long)
        for b, row in enumerate(rows):
            row = row[-L:]
            batch[b, :len(row)] = torch.tensor(row, dtype=torch.long)
        with torch.no_grad():
            logits = self.nm(batch)                      # [B, L, V]
        out = []
        for b, row in enumerate(rows):
            pos = min(len(row), L) - 1
            out.append(torch.log_softmax(logits[b, pos], dim=-1))
        return out

    def neural_next_words(self, context, limit=LIMIT,
                           beam_width=BEAM_WIDTH, max_pieces=MAX_PIECES):
        ctx_ids = self.sp.encode("<en> " + " ".join(context).lower())
        if len(ctx_ids) + max_pieces >= self.L:
            ctx_ids = ctx_ids[-(self.L - max_pieces - 1):]
        if not ctx_ids:
            return []

        beams = [{"tokens": ctx_ids, "surface": "", "lp": 0.0}]
        found = {}
        root = self.trie.root

        for _ in range(max_pieces):
            dists = self._last_token_logprobs([b["tokens"] for b in beams])
            expanded = []
            for beam, dist in zip(beams, dists):
                if beam["surface"] and is_word(root, beam["surface"]):
                    end = -math.inf
                    for bid in self.boundary_ids:
                        end = logaddexp(end, dist[bid].item())
                    score = beam["lp"] + end
                    if score > found.get(beam["surface"], -math.inf):
                        found[beam["surface"]] = score

                top_vals, top_idx = torch.topk(dist, min(TOPK_PER_STEP, dist.numel()))
                for lp, tid in zip(top_vals.tolist(), top_idx.tolist()):
                    piece = self.sp.id_to_piece(tid)
                    if not piece or piece.startswith("<"):
                        continue
                    if not beam["surface"]:
                        if len(piece) <= 1 or not piece.startswith("▁"):
                            continue
                        surface = piece[1:]
                    else:
                        if piece.startswith("▁"):
                            continue
                        surface = beam["surface"] + piece
                    if not is_prefix(root, surface):
                        continue
                    expanded.append({
                        "tokens": beam["tokens"] + [tid],
                        "surface": surface,
                        "lp": beam["lp"] + lp,
                    })
            beams = heapq.nlargest(beam_width, expanded, key=lambda b: b["lp"])
            if not beams:
                break

        ranked = sorted(found.items(), key=lambda kv: -kv[1])
        return ranked[:limit]


def run(models, context_str):
    context = context_str.strip().split()
    ng = models.ngram_next_words(context)
    neu = models.neural_next_words(context)

    print(f"\ncontext = {context!r}")
    print(f"{'#':>2}  {'n-gram (corpus counts)':30}  {'neural beam search (score)':30}")
    rows = max(len(ng), len(neu))
    for i in range(rows):
        left = ng[i] if i < len(ng) else ""
        if i < len(neu):
            word, score = neu[i]
            right = f"{word} ({score:.2f})"
        else:
            right = ""
        print(f"{i+1:>2}  {left:30}  {right:30}")
    if not ng and not neu:
        print("  (no predictions — try a shorter / more common context)")


def main():
    models = NextWordModels()
    if len(sys.argv) > 1:
        run(models, " ".join(sys.argv[1:]))
        return
    print("\nType a context (oldest -> newest words). Blank line / Ctrl-D to quit.")
    try:
        while True:
            line = input("\ncontext> ")
            if not line.strip():
                break
            run(models, line)
    except (EOFError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
