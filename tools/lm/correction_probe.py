#!/usr/bin/env python3
"""Interactive autocorrect probe — Python twin of KeyboardEngine.correction(from:)
in Keyboardengine.swift: given a typed string (+ optional left context), generate
noisy-channel candidates from the trie, score each with the pre-trained neural LM
and the corpus n-gram, blend them (BlendedScorer: 0.7 neural + 0.3 n-gram), and
apply the SAME margin gate the device uses to decide whether to fire a correction.

Mirrors two production paths:
  OOV path       (typed string not in the dictionary) — correctionMargin = 3.0,
                 fires whenever the best candidate beats the typed string's own
                 blended score by more than that.
  real-word path (typed string IS in the dictionary, e.g. "hoe"->"how") —
                 realWordMargin = 5.0, and the winning neighbour must additionally
                 sit within realWordMaxCost (1.6, ~1 edit) of the typed word.

Budget note: the device's edit-distance budget (KeyboardEngine.maxCost) is tight
by design (~1-3 edits depending on length) so keyboard mash / IDs never get
"corrected" into unrelated real words. Badly garbled input can legitimately
produce ZERO candidates within budget — pass --budget (or `| ctx | budget` in the
REPL) to relax it and see what a wider search would surface, and how the neural
model would then rank it.

Usage:
  conda activate ml
  python correction_probe.py coeevitjkn                    # one-shot, empty context
  python correction_probe.py coeevitjkn --context auto      # with left context
  python correction_probe.py coeevitjkn --budget 6.0         # relax the channel budget
  python correction_probe.py                                 # interactive REPL
    correction> coeevitjkn
    correction> coeevitjkn | auto
    correction> coeevitjkn | auto | 6.0        (typed | context | budget-override)
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import sentencepiece as sspm
import torch

from eval_harness import LangData, Trie, logprob, cost_budget, LANGDATA, FREQ_W, LM_W

PAD = 3
W_NEURAL, W_NGRAM = 0.7, 0.3        # BlendedScorer weights
CORRECTION_MARGIN = 3.0             # KeyboardEngine.correctionMargin (OOV path)
REAL_WORD_MARGIN = 5.0              # KeyboardEngine.realWordMargin (real-word path)
REAL_WORD_MAX_COST = 1.6            # KeyboardEngine.realWordMaxCost
SCORE_CAP = 16                      # KeyboardEngine.scoreCap (Core ML batch limit)
TOPN = SCORE_CAP - 1                # one slot reserved for the typed-word row


class CorrectionModels:
    def __init__(self):
        print("loading langdata.bin + trie ...", file=sys.stderr)
        self.ld = LangData(LANGDATA)
        self.trie = Trie(self.ld)

        print("loading tokenizer + TinyLM (data/lm.pt) ...", file=sys.stderr)
        self.sp = sspm.SentencePieceProcessor(model_file=str(HERE / "data/spm.model"))
        ckpt = torch.load(HERE / "data/lm.pt", map_location="cpu", weights_only=False)
        from model import TinyLM
        self.nm = TinyLM(vocab=ckpt["vocab"])
        self.nm.load_state_dict(ckpt["model"])
        self.nm.eval()
        self.L = self.nm.maxlen

    def neural_lp(self, word, context):
        """Summed logP(word | context) — same layout as NeuralScorer.scores
        (shared context prefix, one causal forward, no length normalization).
        Lowercase like the Swift engine: the 6k vocab is [a-z' ] only, so any
        capital letter degrades into byte-fallback pieces the model barely saw."""
        ids = self.sp.encode("<en> " + " ".join(context).lower())
        cand = self.sp.encode(" " + word)
        seq = (ids + cand)[-self.L:]
        cstart = len(seq) - len(cand)
        row = seq + [PAD] * (self.L - len(seq))
        with torch.no_grad():
            lp = torch.log_softmax(self.nm(torch.tensor([row]))[0], dim=-1)
        return sum(lp[cstart - 1 + i, t].item() for i, t in enumerate(cand))


def build_table(models, typed, context, budget=None):
    typed_lw = typed.lower()
    context = [w.lower() for w in context]      # engine lowercases before every lookup
    is_real_word = typed_lw in models.ld.ids
    b = budget if budget is not None else cost_budget(len(typed_lw))

    cands = models.trie.search(typed_lw, max_cost=b)
    cands.sort(key=lambda t: -t[1] + FREQ_W * t[2], reverse=True)
    kept = cands[:TOPN]

    # When the typed string is itself a dictionary word, the trie DP always finds
    # it at cost 0 (self-match) — mirrors KeyboardEngine.rank()'s dedup-by-word,
    # which keeps that entry and skips the separately-passed `extra` typed row.
    # Only synthesize a typed row here when the trie search didn't already supply one.
    if any(w == typed_lw for w, _, _ in kept):
        rows_source = kept
    else:
        typed_wid = models.ld.ids.get(typed_lw)
        typed_lf = __import__("math").log(models.ld.freqs[typed_wid] + 1) if typed_wid is not None else 0.0
        rows_source = kept + [(typed_lw, 0.0, typed_lf)]

    rows = []
    for w, cost, lf in rows_source:
        n = models.neural_lp(w, context)
        g = logprob(models.ld, w, context)
        prior = W_NEURAL * n + W_NGRAM * g
        final = -cost + LM_W * prior + FREQ_W * lf
        rows.append(dict(word=w, cost=cost, neural=n, ngram=g, prior=prior, final=final))
    rows.sort(key=lambda r: -r["final"])
    return rows, is_real_word, b, len(cands)


def apostrophe_restoration(ld, lw):
    """Mirror of Lexicon.apostropheRestoration: the most frequent vocab word formed
    by inserting one apostrophe ("dont" -> "don't"). None when nothing matches."""
    if "'" in lw or len(lw) < 2:
        return None
    best = None
    for i in range(1, len(lw)):
        cand = lw[:i] + "'" + lw[i:]
        wid = ld.ids.get(cand)
        if wid is not None and (best is None or ld.freqs[wid] > best[1]):
            best = (cand, ld.freqs[wid])
    return best[0] if best else None


def gate(rows, typed_lw, is_real_word):
    typed_row = next(r for r in rows if r["word"] == typed_lw)
    best = rows[0]
    if is_real_word:
        threshold = REAL_WORD_MARGIN
        eligible = best["word"] != typed_lw and best["cost"] <= REAL_WORD_MAX_COST
        rule = f"real-word path: margin > {threshold}  AND  cost <= {REAL_WORD_MAX_COST}"
    else:
        threshold = CORRECTION_MARGIN
        eligible = best["word"] != typed_lw
        rule = f"OOV path: margin > {threshold}"
    margin = best["final"] - typed_row["final"]
    fire = eligible and margin > threshold
    return margin, threshold, fire, rule, best["word"] if fire else None


def run(models, typed, context, budget=None):
    typed_lw = typed.lower()
    if typed_lw not in models.ld.ids:
        restored = apostrophe_restoration(models.ld, typed_lw)
        if restored:
            print(f"\ntyped = {typed_lw!r}  (OOV, apostrophe restoration)")
            print(f"=> CORRECT  {typed_lw!r} -> {restored!r}  (fires before scoring, like the engine)")
            return
    rows, is_real_word, used_budget, n_cands = build_table(models, typed, context, budget)
    print(f"\ntyped = {typed_lw!r}  context = {context!r}  "
          f"{'(real dictionary word)' if is_real_word else '(OOV)'}")
    print(f"channel budget = {used_budget:.2f}  ->  {n_cands} candidate(s) within budget"
          + ("" if budget is not None else "  (device default for this length)"))
    if n_cands == 0:
        print("  no correction candidates generated at this budget — "
              "try `| <ctx> | <budget>` (e.g. `| | 6.0`) to see what a wider search finds")

    print(f"\n{'candidate':14} {'channel':>8} {'neural':>8} {'n-gram':>8} {'blend':>8} {'final':>8}")
    for r in rows[:12]:
        mark = "  <- typed" if r["word"] == typed_lw else ""
        print(f"{r['word']:14} {-r['cost']:8.2f} {r['neural']:8.2f} {r['ngram']:8.2f} "
              f"{r['prior']:8.2f} {r['final']:8.2f}{mark}")

    margin, threshold, fire, rule, winner = gate(rows, typed_lw, is_real_word)
    print(f"\n{rule}")
    print(f"best candidate margin over typed = {margin:.2f}")
    print("=> " + (f"CORRECT  {typed_lw!r} -> {winner!r}" if fire else "keep typed (no correction)"))


def parse_repl_line(line):
    parts = [p.strip() for p in line.split("|")]
    typed = parts[0]
    context = parts[1].split() if len(parts) > 1 and parts[1] else []
    budget = float(parts[2]) if len(parts) > 2 and parts[2] else None
    return typed, context, budget


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("typed", nargs="?", help="the typed (possibly garbled) word")
    ap.add_argument("--context", default="", help="space-separated left context")
    ap.add_argument("--budget", type=float, default=None,
                     help="override the channel edit-distance budget (device default if omitted)")
    args = ap.parse_args()

    models = CorrectionModels()

    if args.typed:
        run(models, args.typed, args.context.split(), args.budget)
        return

    print("\nType: <word> [| context words [| budget]]. Blank line / Ctrl-D to quit.")
    print("e.g.  coeevitjkn        coeevitjkn | auto        coeevitjkn | auto | 6.0")
    try:
        while True:
            line = input("\ncorrection> ")
            if not line.strip():
                break
            typed, context, budget = parse_repl_line(line)
            run(models, typed, context, budget)
    except (EOFError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
