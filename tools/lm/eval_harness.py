#!/usr/bin/env python3
"""The measurement rig: correction top-1/top-3 on synthetic (typed, intended,
context) triples, for the n-gram baseline and optionally +neural rescoring.

Typos are SAMPLED FROM THE SAME CHANNEL MODEL the Swift engine assumes
(adjacent-key Gaussian slips, insertions, deletions), so the noise
distribution matches the decoder. Candidates + scores are a faithful Python
port of Keyboardengine.swift: same trie DP, same maxCost 2.8, same
  S(w) = -cost + lm_w * logP(w|ctx) + freq_w * log(freq+1)
reading the real langdata.bin, so numbers here transfer to the device.

Usage:
  python3 eval_harness.py                 # n-gram baseline
  python3 eval_harness.py --neural        # blend with data/lm.pt rescoring
  python3 eval_harness.py --sweep         # grid the blend weight
"""

import argparse
import bisect
import math
import random
import struct
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE.parent / ".cache"
LANGDATA = HERE.parents[1] / "keyboard" / "langdata.bin"

MAX_COST, LM_W, FREQ_W = 2.8, 1.0, 0.3
INS = DEL = 1.6
TRANS = 0.8          # adjacent-letter swap (Damerau) — mirror of Trie.transCost


def first_letter_penalty(typed_len):
    """Mirror Trie.firstLetterPenaltyPolicy in Keyboardengine.swift: the first-letter
    protection scales with word length, so short first-letter typos (js->is, hw->how)
    can still be generated while long words stay protected."""
    if typed_len <= 2:
        return 0.0
    if typed_len == 3:
        return 0.35
    if typed_len == 4:
        return 0.75
    return 2.5


def cost_budget(length):
    """Dynamic edit-distance budget by typed length — mirrors KeyboardEngine.maxCost(for:).
    Short words ~1 edit, normal ~2, long ~3."""
    if length <= 4:
        return 1.8
    if length <= 7:
        return 2.8
    return 3.6

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
OFFS = [0.0, 0.25, 0.75]
POS = {ch: (c + OFFS[r], float(r)) for r, row in enumerate(ROWS) for c, ch in enumerate(row)}


def sub_cost(a, b):
    if a == b:
        return 0.0
    if a not in POS or b not in POS:
        return 3.0
    d2 = (POS[a][0] - POS[b][0]) ** 2 + (POS[a][1] - POS[b][1]) ** 2
    return min(3.0, d2 / 2 + 0.3)


# ---- langdata.bin reader (mirrors LangData.swift) ----

EMPTY = 0xFFFFFFFF
MASK64 = (1 << 64) - 1


def mix64(x):
    """splitmix64 finalizer — mirrors LangData.mix64 in Swift and the builder."""
    x &= MASK64
    x ^= x >> 30
    x = (x * 0xBF58476D1CE4E5B9) & MASK64
    x ^= x >> 27
    x = (x * 0x94D049BB133111EB) & MASK64
    x ^= x >> 31
    return x


class LangData:
    """Reader for langdata.bin v2/v3/v4 (open-addressing hash tables; v3 adds a static
    trie section, v4 adds a sentence-starters section, both before the word blob)."""

    def __init__(self, path):
        d = self.d = path.read_bytes()
        magic, ver, self.W, self.biBuckets, self.BE, self.triBuckets, self.TE = \
            struct.unpack_from("<7I", d, 0)
        assert magic == 0x4B424C4D and ver in (2, 3, 4), "langdata.bin must be format v2/v3/v4"
        self.trieNodes = struct.unpack_from("<I", d, 28)[0] if ver >= 3 else 0
        self.starterCount = struct.unpack_from("<I", d, 32)[0] if ver >= 4 else 0
        self.freqB = 36 if ver >= 4 else (32 if ver >= 3 else 28)
        self.offsB = self.freqB + 4 * self.W
        self.biHashB = self.offsB + 4 * (self.W + 1)
        self.biEntB = self.biHashB + 16 * self.biBuckets
        self.triHashB = self.biEntB + 8 * self.BE
        self.triEntB = self.triHashB + 20 * self.triBuckets
        self.trieB = self.triEntB + 8 * self.TE
        self.startersB = self.trieB + 14 * self.trieNodes
        self.blobB = self.startersB + 8 * self.starterCount
        self.words = [self.word(i) for i in range(self.W)]
        self.ids = {w: i for i, w in enumerate(self.words)}
        self.freqs = list(struct.unpack_from(f"<{self.W}I", d, self.freqB))

    def word(self, i):
        a, b = struct.unpack_from("<2I", self.d, self.offsB + 4 * i)
        return self.d[self.blobB + a:self.blobB + b].decode()

    def _entries(self, base, start, count):
        return [struct.unpack_from("<2I", self.d, base + 8 * j) for j in range(start, start + count)]

    def bigrams(self, ctx):
        if self.biBuckets == 0:
            return None
        mask = self.biBuckets - 1
        b = mix64(ctx) & mask
        while True:
            slot, total, start, count = struct.unpack_from("<4I", self.d, self.biHashB + 16 * b)
            if slot == EMPTY:
                return None
            if slot == ctx:
                return total, self._entries(self.biEntB, start, count)
            b = (b + 1) & mask

    def trigrams(self, a, c):
        if self.triBuckets == 0:
            return None
        mask = self.triBuckets - 1
        b = mix64((a << 32) | c) & mask
        while True:
            w1, w2, total, start, count = struct.unpack_from("<5I", self.d, self.triHashB + 20 * b)
            if w1 == EMPTY:
                return None
            if w1 == a and w2 == c:
                return total, self._entries(self.triEntB, start, count)
            b = (b + 1) & mask


# ---- trie with the same weighted DP as Trie.swift ----

class Trie:
    def __init__(self, ld):
        self.root = {}
        for i, w in enumerate(ld.words):
            node = self.root
            for ch in w:
                node = node.setdefault(ch, {})
            node["$"] = (w, math.log(ld.freqs[i] + 1))

    def search(self, typed, max_cost=None):
        if max_cost is None:
            max_cost = cost_budget(len(typed))   # dynamic budget, like the device
        out = []
        first = [i * INS for i in range(len(typed) + 1)]

        def rec(node, letter, prev_letter, depth, prev, prev2):
            cur = [prev[0] + DEL]
            for col in range(1, len(typed) + 1):
                s = sub_cost(letter, typed[col - 1])
                if depth == 1 and col == 1 and letter != typed[0]:
                    s += first_letter_penalty(len(typed))
                v = min(cur[col - 1] + INS, prev[col] + DEL, prev[col - 1] + s)
                # Transposition: candidate's last two letters are the typed pair swapped.
                if depth >= 2 and col >= 2 and letter == typed[col - 2] and prev_letter == typed[col - 1]:
                    v = min(v, prev2[col - 2] + TRANS)
                cur.append(v)
            if "$" in node and cur[-1] <= max_cost:
                out.append((node["$"][0], cur[-1], node["$"][1]))
            if min(cur) <= max_cost:
                for ch, child in node.items():
                    if ch != "$":
                        rec(child, ch, letter, depth + 1, cur, prev)

        for ch, child in self.root.items():
            if ch != "$":
                rec(child, ch, "", 1, first, None)
        return out


def logprob(ld, w, ctx):
    """Stupid backoff, base counts only (fresh-install condition)."""
    wid = ld.ids.get(w)
    if len(ctx) >= 2 and wid is not None:
        a, b = ld.ids.get(ctx[-2]), ld.ids.get(ctx[-1])
        if a is not None and b is not None and (hit := ld.trigrams(a, b)):
            tot, ents = hit
            c = next((n for word, n in ents if word == wid), 0)
            if c:
                return math.log(c / tot)
    if len(ctx) >= 1 and wid is not None:
        a = ld.ids.get(ctx[-1])
        if a is not None and (hit := ld.bigrams(a)):
            tot, ents = hit
            c = next((n for word, n in ents if word == wid), 0)
            if c:
                return math.log(0.4 * c / tot)
    return math.log(0.16 / 1000)   # empty user model floor


def context_is_sparse(ld, ctx):
    """True when the trigram context has no table entry — the n-gram must back off
    to bigram/unigram and is effectively context-blind. This is the regime a
    neural LM is supposed to rescue, and where a fair comparison lives."""
    if len(ctx) < 2:
        return True
    a, b = ld.ids.get(ctx[-2]), ld.ids.get(ctx[-1])
    if a is None or b is None:
        return True
    return ld.trigrams(a, b) is None


ADJ = {ch: [o for o in POS if o != ch and sub_cost(ch, o) < 1.2] for ch in POS}


def corrupt(word, rng, edits=1):
    """Sample a typo from the channel model. Never the first letter (matches
    the first-letter prior), always at least one edit. `edits` > 1 stacks
    independent slips — the messier regime where generator recall actually drops."""
    w = list(word)
    for _ in range(edits):
        if len(w) < 2:
            break
        i = rng.randrange(1, len(w))
        r = rng.random()
        if r < 0.7 and w[i] in ADJ:
            w[i] = rng.choice(ADJ[w[i]])
        elif r < 0.85:
            del w[i]
        else:
            w.insert(i, rng.choice(ADJ.get(w[i], [w[i]])))
    return "".join(w)


def pair_cost(typed, intended):
    """Exact channel cost of typed given intended — the same weighted DP the trie
    runs along the path spelling `intended`. Lets the oracle report what a bigger
    maxCost budget would buy without re-searching the whole trie."""
    prev = [i * INS for i in range(len(typed) + 1)]
    for d, letter in enumerate(intended, 1):
        cur = [prev[0] + DEL]
        for col in range(1, len(typed) + 1):
            s = sub_cost(letter, typed[col - 1])
            if d == 1 and col == 1 and letter != typed[0]:
                s += first_letter_penalty(len(typed))
            cur.append(min(cur[col - 1] + INS, prev[col] + DEL, prev[col - 1] + s))
        prev = cur
    return prev[-1]


def make_triples(ld, n, rng, edits=1):
    """(typed, intended, context) from held-out Leipzig sentences."""
    tars = sorted(CACHE.glob("eng_*_1M.tar.gz"))
    assert tars, "run tools/build_language_data.py first (needs the cached corpus)"
    triples = []
    with tarfile.open(tars[0], "r:gz") as tar:
        member = next(m for m in tar.getmembers() if m.name.endswith("-sentences.txt"))
        for raw in tar.extractfile(member):
            if rng.random() < 0.98:      # skim — decorrelates from training data order
                continue
            toks = [t for t in raw.decode(errors="replace").lower().split() if t.isalpha()]
            for i in range(2, len(toks)):
                if len(toks[i]) >= 4 and toks[i] in ld.ids and rng.random() < 0.2:
                    typo = corrupt(toks[i], rng, edits)
                    if typo != toks[i] and typo not in ld.ids:
                        triples.append((typo, toks[i], toks[max(0, i - 8):i]))
            if len(triples) >= n:
                return triples[:n]
    return triples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--neural", action="store_true")
    ap.add_argument("--neural-weight", type=float, default=0.7)
    ap.add_argument("--no-norm", action="store_true", help="use summed (not per-token) neural log-prob")
    ap.add_argument("--sweep", action="store_true", help="grid blend weight x length-norm vs baseline")
    ap.add_argument("--sparse", action="store_true",
                    help="evaluate only where the trigram backs off (neural's real regime)")
    ap.add_argument("--confusable", action="store_true",
                    help="evaluate only ambiguous typos (2+ real words within edit budget)")
    ap.add_argument("--oracle", action="store_true",
                    help="oracle recall@k: can the generator produce the gold word at all, "
                         "and does it survive the crude pre-rank cap? (no scoring/model)")
    ap.add_argument("--edits", type=int, default=1,
                    help="channel edits per typo (default 1; 2+ = the messy regime)")
    args = ap.parse_args()

    rng = random.Random(7)
    ld = LangData(LANGDATA)
    trie = Trie(ld)
    triples = make_triples(ld, args.n, rng, args.edits)
    if args.confusable:
        # Keep only genuinely ambiguous typos: the typed string is within edit budget
        # of 2+ real words, so the CHANNEL alone can't decide — context must. This is
        # the regime a language model exists to serve (the "might vs night" case).
        keep = []
        for typed, intended, ctx in triples:
            cands = [w for w, c, lf in trie.search(typed) if c <= 1.6]
            if intended in cands and len(set(cands)) >= 2:
                keep.append((typed, intended, ctx))
        triples = keep
        print(f"{len(triples)} triples (CONFUSABLE — 2+ real words within edit budget)")
    elif args.sparse:
        triples = [t for t in triples if context_is_sparse(ld, t[2])]
        print(f"{len(triples)} triples (SPARSE context only — n-gram backs off here)")
    else:
        print(f"{len(triples)} triples")

    if args.oracle:
        # Oracle recall = the hard ceiling on every downstream number: if the gold
        # word isn't in the candidate list, no rescorer at any size can save it.
        # Two stages can lose it: (1) the channel prune — pair cost > maxCost, the
        # word never comes out of the trie; (2) the crude pre-rank cap — it comes
        # out, but ranks below what survives to the rescorer (Swift keeps nBest=12
        # of a scoreCap=16 batch). Report both, plus what a bigger budget buys.
        ks = (3, 8, 12, 16, 24)
        budgets = (2.8, 3.2, 3.6, 4.0)
        n = len(triples)
        found, hit_at = 0, {k: 0 for k in ks}
        within = {b: 0 for b in budgets}
        for typed, intended, ctx in triples:
            c = pair_cost(typed, intended)
            for b in budgets:
                within[b] += c <= b
            crude = sorted(trie.search(typed), key=lambda t: -t[1] + FREQ_W * t[2], reverse=True)
            words = [w for w, _, _ in crude]
            if intended in words:
                found += 1
                r = words.index(intended)
                for k in ks:
                    hit_at[k] += r < k
        print(f"\noracle recall (gold word at ANY rank):  {found / n:.3f}")
        print("after crude pre-rank (-cost + freq_w*logFreq) — what the rescorer sees:")
        tags = {12: "  <- Swift nBest", 16: "  <- Swift scoreCap"}
        for k in ks:
            print(f"  recall@{k:<2}  {hit_at[k] / n:.3f}{tags.get(k, '')}")
        print("channel-prune ceiling if maxCost were relaxed (exact pair-cost DP):")
        for b in budgets:
            print(f"  maxCost {b}  {within[b] / n:.3f}" + ("  <- shipped" if b == MAX_COST else ""))
        return

    neural = None
    if args.neural or args.sweep:
        import sentencepiece as sspm
        import torch
        from model import TinyLM
        sp = sspm.SentencePieceProcessor(model_file=str(HERE / "data/spm.model"))
        ckpt = torch.load(HERE / "data/lm.pt", map_location="cpu")
        nm = TinyLM(vocab=ckpt["vocab"]); nm.load_state_dict(ckpt["model"]); nm.eval()

        L = nm.maxlen
        PAD = 3
        def neural_lp(w, ctx, norm):
            ids = sp.encode("<en> " + " ".join(ctx))
            cand = sp.encode(" " + w)
            seq = (ids + cand)[-L:]                       # keep the most recent L tokens
            cstart = len(seq) - len(cand)                 # candidate's start in the window
            row = seq + [PAD] * (L - len(seq))
            with torch.no_grad():
                lp = torch.log_softmax(nm(torch.tensor([row]))[0], -1)
            total = sum(lp[cstart - 1 + i, t].item() for i, t in enumerate(cand))
            return total / len(cand) if norm else total     # per-token vs summed
        neural = neural_lp

    def evaluate(weight, norm):
        # Cache neural scores per (word, ctx-id) so a sweep doesn't re-run the model.
        top1 = top3 = 0
        for ti, (typed, intended, ctx) in enumerate(triples):
            scored = []
            for w, cost, lf in trie.search(typed):
                prior = logprob(ld, w, ctx)
                if neural and weight > 0:
                    key = (w, ti, norm)
                    if key not in cache:
                        cache[key] = neural(w, ctx, norm)
                    prior = weight * cache[key] + (1 - weight) * prior
                scored.append((-cost + LM_W * prior + FREQ_W * lf, w))
            scored.sort(reverse=True)
            ranked = [w for _, w in scored]
            top1 += ranked[:1] == [intended]
            top3 += intended in ranked[:3]
        return top1 / len(triples), top3 / len(triples)

    cache: dict = {}
    if args.sweep:
        print(f"{'weight':>7} {'norm':>5} {'top-1':>6} {'top-3':>6}")
        b1, b3 = evaluate(0.0, False)
        print(f"{'baseline':>7} {'—':>5} {b1:>6.3f} {b3:>6.3f}")
        for norm in (True, False):
            for weight in (0.3, 0.5, 0.7, 0.9):
                t1, t3 = evaluate(weight, norm)
                print(f"{weight:>7.1f} {str(norm):>5} {t1:>6.3f} {t3:>6.3f}")
    else:
        t1, t3 = evaluate(args.neural_weight if neural else 0.0, not args.no_norm)
        tag = "+neural" if neural else "n-gram baseline"
        print(f"top-1 {t1:.3f}   top-3 {t3:.3f}   ({tag})")


if __name__ == "__main__":
    main()
