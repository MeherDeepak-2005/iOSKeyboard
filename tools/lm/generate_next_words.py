#!/usr/bin/env python3
"""Reference implementation of GRU next-word GENERATION (subword beam).

This is the fix for the "generation vs rerank" gap: instead of reranking the n-gram's
next-word pool, decode the GRU's own next-word distribution as a bounded subword beam and
emit complete words — including words the n-gram never proposed. It mirrors, step for step,
what GRULanguagePrior will do in Swift (runContext -> forward_step beam -> collect words),
so it doubles as the on-device parity reference.

  python generate_next_words.py --checkpoint data/gru.pt --tokenizer data/qwen_spm.model \
      --context "i am going to"

Word boundary convention (shared with the SentencePiece tokenizer): a word's first piece is
U+2581 ('_')-prefixed; continuation pieces are not. A partial word is COMPLETE when the model
would next emit another '_'-started piece (the next word begins) or a max-length cap is hit.
"""
import argparse
import math

import torch
import sentencepiece as spm

from model import load_inference_checkpoint

WORD_START = "▁"   # SentencePiece space marker; first piece of every word carries it.


def log_softmax(logits):
    return torch.log_softmax(logits, dim=-1)


class GRUGenerator:
    def __init__(self, checkpoint, tokenizer_path):
        self.model, _ = load_inference_checkpoint(checkpoint)
        self.model.eval()
        self.sp = spm.SentencePieceProcessor(model_file=tokenizer_path)
        self.vocab = self.sp.vocab_size()
        # Special pieces (match the Swift tokenizer's lookups).
        self.pad_id = self._piece_id("<pad>", default=0)
        self.en_id = self._piece_id("<en>", default=None)
        # Precompute, for every id, whether it is word CONTENT and how it attaches.
        #   start-content : "_word" — the first piece of a word (letters/apostrophe only)
        #   cont-content  : "ing"   — a continuation piece (no marker, letters/apostrophe)
        # Punctuation, byte-fallback (<0x..>), digits, and control pieces (</s>, <en>) are
        # NONE of these: they act as word boundaries and never enter a generated word. This is
        # the same alphabetic gate the lexicon applies, so the reference matches on-device.
        self.pieces = [self.sp.id_to_piece(i) for i in range(self.vocab)]
        self.is_start_content = [self._start_content(p) for p in self.pieces]
        self.is_cont_content = [self._cont_content(p) for p in self.pieces]
        # A word ENDS at a hypothesis with the probability that the next token is NOT a
        # continuation of it (a new "_word", punctuation, or EOS). Scoring each candidate word
        # by lp + log P(boundary next) marginalizes the boundary, so a fragment the model wants
        # to keep extending ("apo" -> "apolog...") scores far below a real word ("the", "going").
        self._boundary_mask = torch.tensor(
            [not c for c in self.is_cont_content], dtype=torch.bool)

    @staticmethod
    def _is_alpha(text):
        return len(text) > 0 and all("a" <= c <= "z" or c == "'" for c in text)

    def _start_content(self, piece):
        return piece.startswith(WORD_START) and self._is_alpha(piece[len(WORD_START):].lower())

    def _cont_content(self, piece):
        return not piece.startswith(WORD_START) and self._is_alpha(piece.lower())

    def _piece_id(self, piece, default):
        pid = self.sp.piece_to_id(piece)
        # SentencePiece returns unk id for unknown pieces; treat that as absent.
        if pid == self.sp.unk_id() and piece != "<unk>":
            return default
        return pid

    def encode_context(self, context_words):
        text = " ".join(context_words).lower().strip()
        ids = [self.en_id] if self.en_id is not None else []
        if text:
            ids += self.sp.encode(text, out_type=int)
        if not ids:
            ids = [self.pad_id]
        return ids

    @torch.no_grad()
    def _run_context(self, tokens):
        """Thread the context through the GRU exactly as Swift runContext does: start from a
        pad `prev`, step once per context token (so the sequence consumed is [pad, t0 .. t_{n-2}]),
        and hand back the last context token as the `prev` fed into the first generation step —
        so the full context [pad, t0 .. t_{n-1}] is what conditions the first predicted word."""
        state = self.model.empty_state(batch=1)
        prev = torch.tensor([self.pad_id], dtype=torch.long)
        for tok in tokens:
            _, state = self.model.forward_step(prev, state)
            prev = torch.tensor([tok], dtype=torch.long)
        return state, tokens[-1]

    @torch.no_grad()
    def _step(self, prev_token, state):
        logits, new_state = self.model.forward_step(
            torch.tensor([prev_token], dtype=torch.long), state)
        return logits[0], new_state          # logits: [vocab]

    def decode_word(self, piece_ids):
        return "".join(self.pieces[i] for i in piece_ids).replace(WORD_START, "").strip()

    def _start_letter_ok(self, tok, first_letters):
        """Prefix gate for seeding: a word-start piece's first letter must be in `first_letters`
        (mirrors GRULanguagePrior.startLetterAllowed, which reads the tokenizer's startFirstLetter)."""
        if first_letters is None:
            return True
        piece = self.pieces[tok][len(WORD_START):].lower()
        return bool(piece) and piece[0] in first_letters

    @torch.no_grad()
    def generate(self, context_words, k=24, beam=16, branch=8, max_pieces=6,
                 first_letters=None):
        """Return up to `k` (word, logprob) next-word candidates, best first.

        beam    : partial word hypotheses carried between depths
        branch  : top tokens considered per hypothesis per step
        max_pieces : hard cap on pieces per generated word
        first_letters : optional set of lowercased chars; when given, PREFIX-aware generation seeds
                        only word-starts whose first letter is in the set (the Swift beam constrains
                        seeding to letters spatially reachable from the first tap — same gate).
        """
        tokens = self.encode_context(context_words)
        ctx_state, last = self._run_context(tokens)

        # A hypothesis = (piece_ids, logprob, state, prev_token). Seed one empty hypothesis
        # holding the context state and the last context token as `prev`.
        Hyp = lambda pids, lp, st, prev: (pids, lp, st, prev)
        frontier = [Hyp([], 0.0, ctx_state, last)]
        completed = {}   # word -> best logprob

        for depth in range(max_pieces):
            scored = []
            for pids, lp, state, prev in frontier:
                logits, nstate = self._step(prev, state)
                lps = log_softmax(logits)
                # Record the word ending HERE, weighted by the probability it ends here.
                if pids:
                    word = self.decode_word(pids)
                    if word:
                        boundary = torch.logsumexp(lps[self._boundary_mask], dim=0).item()
                        completed[word] = max(completed.get(word, -math.inf), lp + boundary)
                # Extend the beam only along continuation pieces (word-start / punctuation /
                # byte / EOS are boundaries — they end the word, handled above).
                top = torch.topk(lps, branch)
                for score, tok in zip(top.values.tolist(), top.indices.tolist()):
                    if not pids:
                        if self.is_start_content[tok] and self._start_letter_ok(tok, first_letters):
                            scored.append(([tok], lp + score, nstate, tok))
                    elif self.is_cont_content[tok]:
                        scored.append((pids + [tok], lp + score, nstate, tok))
            if not scored:
                break
            scored.sort(key=lambda h: h[1], reverse=True)
            frontier = scored[:beam]

        ranked = sorted(completed.items(), key=lambda kv: kv[1], reverse=True)
        return ranked[:k]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="data/gru.pt")
    ap.add_argument("--tokenizer", default="data/qwen_spm.model")
    ap.add_argument("--context", default="i am going to")
    ap.add_argument("-k", type=int, default=20)
    ap.add_argument("--wordlist", default=None,
                    help="optional newline word list; reports how many generated words are in it")
    ap.add_argument("--first-letters", default=None,
                    help="prefix-aware demo: only generate words starting with one of these letters "
                         "(e.g. 'wqes' for a 'w' tap and its neighbours)")
    args = ap.parse_args()
    first_letters = set(args.first_letters.lower()) if args.first_letters else None

    gen = GRUGenerator(args.checkpoint, args.tokenizer)
    print(f"vocab={gen.vocab}  pad={gen.pad_id}  <en>={gen.en_id}  "
          f"start-content={sum(gen.is_start_content)}  cont-content={sum(gen.is_cont_content)}")

    lexicon = None
    if args.wordlist:
        lexicon = set(w.strip().lower() for w in open(args.wordlist) if w.strip())

    demos = [args.context] if args.context else []
    demos += ["i am going to", "see you", "on my", "thanks for the", "what are you",
              "let me know", "i will be", "happy"]
    seen = set()
    for ctx in demos:
        if ctx in seen:
            continue
        seen.add(ctx)
        words = ctx.split()
        out = gen.generate(words, k=args.k, first_letters=first_letters)
        tail = ""
        if lexicon is not None:
            hit = sum(1 for w, _ in out if w in lexicon)
            tail = f"   [{hit}/{len(out)} in lexicon]"
        print(f"\nctx: \"{ctx}\"{tail}")
        print("  " + ", ".join(f"{w}({lp:.1f})" for w, lp in out))


if __name__ == "__main__":
    main()
