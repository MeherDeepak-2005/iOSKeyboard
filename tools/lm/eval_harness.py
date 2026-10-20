#!/usr/bin/env python3
"""Offline correction benchmark for the n-gram baseline and research LMs.

The n-gram probability below mirrors the fresh-install Witten-Bell interpolation
in ``NgramScorer.swift``. Candidate generation remains a Python approximation of
the production decoder: it does not model completion/context-injection policy,
personalization, cancellation, Core ML, or iPhone runtime behavior. Synthetic
results are useful for regression screening only and MUST NOT be presented as
device or real-user quality claims.

Usage:
  python3 eval_harness.py                 # n-gram baseline
  python3 eval_harness.py --dataset blind.jsonl
  python3 eval_harness.py --neural        # legacy research checkpoint only
  python3 eval_harness.py --checkpoint /path/to/distill.pt --no-norm
  python3 eval_harness.py --sweep         # grid the blend weight

JSONL rows use: {"typed":"...", "intended":"...", "context":["..."],
"user_id":"...", "split":"test"}. ``user_id`` and ``split`` are optional,
but --require-user-separated makes them mandatory and rejects split leakage.
"""

import argparse
import bisect
import hashlib
import json
import math
import random
import statistics
import struct
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = HERE.parent / ".cache"
LANGDATA = HERE.parents[1] / "keyboard" / "langdata.bin"

LM_W, FREQ_W = 1.0, 0.3
INS = DEL = 1.6
TRANS = 0.8          # adjacent-letter swap (Damerau) — mirror of Trie.transCost
APOS_SKIP = 0.4      # omitted apostrophe (whats -> what's) — mirror of KB.apostropheSkipCost


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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
OFFS = [0.0, 0.5, 1.5]
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
    """Reader for legacy v2-v4 hash tables and v5 sorted packed records."""

    def __init__(self, path):
        d = self.d = path.read_bytes()
        magic, ver, self.W, self.biBuckets, self.BE, self.triBuckets, self.TE = \
            struct.unpack_from("<7I", d, 0)
        assert magic == 0x4B424C4D and ver in (2, 3, 4, 5, 6), "unsupported langdata.bin format"
        self.version = ver
        self.trieNodes = struct.unpack_from("<I", d, 28)[0] if ver >= 3 else 0
        self.starterCount = struct.unpack_from("<I", d, 32)[0] if ver >= 4 else 0
        self.freqB = 36 if ver >= 4 else (32 if ver >= 3 else 28)
        self.offsB = self.freqB + 4 * self.W
        self.biHashB = self.offsB + 4 * (self.W + 1)
        self.entrySize = 6 if ver == 5 else 8
        self.nodeSize = 12 if ver == 5 else 14
        self.starterSize = 6 if ver == 5 else 8
        self.biEntB = self.biHashB + (12 if ver == 5 else 16) * self.biBuckets
        self.triHashB = self.biEntB + self.entrySize * self.BE
        self.triEntB = self.triHashB + (12 if ver == 5 else 20) * self.triBuckets
        self.trieB = self.triEntB + self.entrySize * self.TE
        self.startersB = self.trieB + self.nodeSize * self.trieNodes
        self.blobB = self.startersB + self.starterSize * self.starterCount
        self.words = [self.word(i) for i in range(self.W)]
        self.ids = {w: i for i, w in enumerate(self.words)}
        self.freqs = list(struct.unpack_from(f"<{self.W}I", d, self.freqB))

    def word(self, i):
        a, b = struct.unpack_from("<2I", self.d, self.offsB + 4 * i)
        return self.d[self.blobB + a:self.blobB + b].decode()

    def _entries(self, base, start, count):
        fmt = "<HI" if self.version == 5 else "<2I"
        return [struct.unpack_from(fmt, self.d, base + self.entrySize * j)
                for j in range(start, start + count)]

    def bigrams(self, ctx):
        if self.biBuckets == 0:
            return None
        if self.version == 6:
            lo, hi = 0, self.biBuckets
            while lo < hi:
                mid = (lo + hi) // 2
                slot = struct.unpack_from("<I", self.d, self.biHashB + 16 * mid)[0]
                if slot < ctx:
                    lo = mid + 1
                else:
                    hi = mid
            if lo == self.biBuckets:
                return None
            slot, total, start, count = struct.unpack_from("<4I", self.d, self.biHashB + 16 * lo)
            return (total, self._entries(self.biEntB, start, count)) if slot == ctx else None
        if self.version == 5:
            lo, hi = 0, self.biBuckets
            while lo < hi:
                mid = (lo + hi) // 2
                slot = struct.unpack_from("<H", self.d, self.biHashB + 12 * mid)[0]
                if slot < ctx:
                    lo = mid + 1
                else:
                    hi = mid
            if lo == self.biBuckets:
                return None
            slot, count, total, start = struct.unpack_from(
                "<HHII", self.d, self.biHashB + 12 * lo)
            return (total, self._entries(self.biEntB, start, count)) if slot == ctx else None
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
        if self.version == 6:
            lo, hi = 0, self.triBuckets
            while lo < hi:
                mid = (lo + hi) // 2
                pair = struct.unpack_from("<2I", self.d, self.triHashB + 20 * mid)
                if pair < (a, c):
                    lo = mid + 1
                else:
                    hi = mid
            if lo == self.triBuckets:
                return None
            w1, w2, total, start, count = struct.unpack_from("<5I", self.d, self.triHashB + 20 * lo)
            return (total, self._entries(self.triEntB, start, count)) if (w1, w2) == (a, c) else None
        if self.version == 5:
            key = (a << 16) | c
            lo, hi = 0, self.triBuckets
            while lo < hi:
                mid = (lo + hi) // 2
                slot = struct.unpack_from("<I", self.d, self.triHashB + 12 * mid)[0]
                if slot < key:
                    lo = mid + 1
                else:
                    hi = mid
            if lo == self.triBuckets:
                return None
            slot, total, start = struct.unpack_from("<III", self.d, self.triHashB + 12 * lo)
            if slot != key:
                return None
            end = (struct.unpack_from("<I", self.d, self.triHashB + 12 * (lo + 1) + 8)[0]
                   if lo + 1 < self.triBuckets else self.TE)
            return total, self._entries(self.triEntB, start, end - start)
        mask = self.triBuckets - 1
        b = mix64((a << 32) | c) & mask
        while True:
            w1, w2, total, start, count = struct.unpack_from("<5I", self.d, self.triHashB + 20 * b)
            if w1 == EMPTY:
                return None
            if w1 == a and w2 == c:
                return total, self._entries(self.triEntB, start, count)
            b = (b + 1) & mask

    def iter_trigrams(self):
        for i in range(self.triBuckets):
            if self.version == 5:
                key = struct.unpack_from("<I", self.d, self.triHashB + 12 * i)[0]
                first, second = key >> 16, key & 0xffff
            else:
                first, second = struct.unpack_from("<2I", self.d, self.triHashB + 20 * i)
                if first == EMPTY:
                    continue
            yield first, second, self.trigrams(first, second)[1]


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

        def rec(node, letter, prev_letter, depth, prev, prev2, first_penalty):
            skip = APOS_SKIP if letter == "'" else DEL   # omitted-apostrophe discount
            cur = [prev[0] + skip]
            for col in range(1, len(typed) + 1):
                s = sub_cost(letter, typed[col - 1])
                v = min(cur[col - 1] + INS, prev[col] + skip, prev[col - 1] + s)
                # Transposition: candidate's last two letters are the typed pair swapped.
                if depth >= 2 and col >= 2 and letter == typed[col - 2] and prev_letter == typed[col - 1]:
                    v = min(v, prev2[col - 2] + TRANS)
                cur.append(v)
            final_cost = cur[-1] + first_penalty
            if "$" in node and final_cost <= max_cost:
                out.append((node["$"][0], final_cost, node["$"][1]))
            if min(cur) + first_penalty <= max_cost:
                for ch, child in node.items():
                    if ch != "$":
                        rec(child, ch, letter, depth + 1, cur, prev, first_penalty)

        for ch, child in self.root.items():
            if ch != "$":
                branch_penalty = (first_letter_penalty(len(typed))
                                  if ch != typed[0] else 0.0)
                rec(child, ch, "", 1, first, None, branch_penalty)
        return out


def mkn_discounts(counts):
    """Chen–Goodman D1, D2, D3+; bounded 0.75 fallback for absent buckets."""
    from collections import Counter
    n = Counter(counts)
    y = n[1] / (n[1] + 2 * n[2]) if n[1] else 0.75
    return [min(k, max(0.0, k - (k + 1) * y * n[k + 1] / n[k]))
            if n[k] and n[k + 1] else 0.75 for k in (1, 2, 3)]


class ModifiedKneserNey:
    def __init__(self, ld):
        from collections import Counter, defaultdict
        self.unigrams = Counter()
        raw_bigrams = {}
        for previous in range(ld.W):
            hit = ld.bigrams(previous)
            if hit:
                raw_bigrams[previous] = {w: c for w, c in hit[1] if c > 0}
                self.unigrams.update(raw_bigrams[previous].keys())
        lower = defaultdict(Counter)
        tri_histogram = Counter()
        for _, second, entries in ld.iter_trigrams():
            for word, count in entries:
                if count > 0:
                    lower[second][word] += 1
                    if count <= 4:
                        tri_histogram[count] += 1
        self.tri_discounts = mkn_discounts(
            k for k, n in tri_histogram.items() for _ in range(n))
        effective = lower if lower else raw_bigrams
        self.bi_discounts = mkn_discounts(c for row in effective.values() for c in row.values())
        self.bigrams = {ctx: self.prepare(row.items(), self.bi_discounts)
                        for ctx, row in effective.items()}
        self.total = sum(self.unigrams.values()) + 0.5

    @staticmethod
    def prepare(entries, discounts):
        counts, total, mass = {}, 0, 0.0
        for word, count in sorted(entries):
            if count <= 0:
                continue
            discount = discounts[min(count, 3) - 1]
            counts[word] = max(count - discount, 0.0)
            total += count
            mass += discount
        return total, mass, counts

    @staticmethod
    def interpolate(row, wid, backoff):
        if row is None or row[0] <= 0:
            return backoff
        total, mass, counts = row
        return counts.get(wid, 0.0) / total + mass / total * backoff


def mkn_logprob(ld, w, ctx):
    """Explicit modified Kneser–Ney experiment, mirroring NgramScorer.swift.

    Counts and continuation statistics come from retained entries. Personal boosts
    are intentionally absent from this immutable-model evaluation.
    """
    if not hasattr(ld, "_mkn"):
        ld._mkn = ModifiedKneserNey(ld)
    model = ld._mkn
    wid = ld.ids.get(w)
    probability = model.unigrams.get(wid, 0.5) / model.total
    if ctx:
        probability = model.interpolate(model.bigrams.get(ld.ids.get(ctx[-1])), wid, probability)
    if len(ctx) >= 2:
        first, second = ld.ids.get(ctx[-2]), ld.ids.get(ctx[-1])
        hit = ld.trigrams(first, second) if first is not None and second is not None else None
        if hit:
            row = model.prepare(hit[1], model.tri_discounts)
            probability = model.interpolate(row, wid, probability)
    return math.log(max(probability, float.fromhex("0x0.0000000000001p-1022")))


def logprob(ld, w, ctx):
    """Production Witten–Bell, including the original sparse-context floor of 8."""
    if not hasattr(ld, '_wb_total'):
        ld._wb_total = sum(ld.freqs) + ld.W
    wid = ld.ids.get(w)
    probability = (ld.freqs[wid] + 1 if wid is not None else 0.5) / ld._wb_total
    hits = []
    previous = ld.ids.get(ctx[-1]) if ctx else None
    first = ld.ids.get(ctx[-2]) if len(ctx) >= 2 else None
    if previous is not None:
        hits.append(ld.bigrams(previous))
    if first is not None and previous is not None:
        hits.append(ld.trigrams(first, previous))
    for hit in hits:
        if hit and hit[0] > 0 and hit[1]:
            total, entries = hit
            weight = total / (total + len(entries)) * total / (total + 8.0)
            count = next((count for word, count in entries if word == wid), 0)
            probability = weight * count / total + (1 - weight) * probability
    return math.log(max(probability, float.fromhex('0x0.0000000000001p-1022')))


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
    if not typed or not intended:
        return len(typed) * INS if not intended else len(intended) * DEL
    branch_penalty = (first_letter_penalty(len(typed))
                      if intended[0] != typed[0] else 0.0)
    prev = [i * INS for i in range(len(typed) + 1)]
    for d, letter in enumerate(intended, 1):
        skip = APOS_SKIP if letter == "'" else DEL   # mirror of the trie DPs
        cur = [prev[0] + skip]
        for col in range(1, len(typed) + 1):
            s = sub_cost(letter, typed[col - 1])
            cur.append(min(cur[col - 1] + INS, prev[col] + skip, prev[col - 1] + s))
        prev = cur
    return prev[-1] + branch_penalty


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


def load_jsonl(path, split=None, require_user_separated=False):
    """Load real labels and reject cross-split user leakage when identities exist."""
    cases = []
    user_splits = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip():
            continue
        try:
            row = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
        typed = str(row.get("typed", "")).strip().lower()
        intended = str(row.get("intended", "")).strip().lower()
        context_value = row.get("context", [])
        context = context_value.split() if isinstance(context_value, str) else list(context_value)
        context = [str(word).lower() for word in context][-8:]
        row_split = row.get("split")
        user_id = row.get("user_id")
        if not typed or not intended:
            raise ValueError(f"{path}:{line_number}: typed and intended are required")
        if require_user_separated and (not user_id or not row_split):
            raise ValueError(f"{path}:{line_number}: user_id and split are required")
        if user_id and row_split:
            previous = user_splits.setdefault(str(user_id), str(row_split))
            if previous != str(row_split):
                raise ValueError(
                    f"user {user_id!r} occurs in both {previous!r} and {row_split!r}"
                )
        if split is None or row_split == split:
            cases.append((typed, intended, context))
    if not cases:
        raise ValueError(f"no benchmark rows selected from {path}")
    return cases


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


class NeuralWordScorer:
    """Batched, exact whole-word scorer for legacy and 10.6M checkpoints."""

    def __init__(self, checkpoint_path: Path, tokenizer_path: Path):
        import sentencepiece as spm
        import torch
        from model import load_inference_checkpoint

        self.torch = torch
        self.model, self.checkpoint = load_inference_checkpoint(checkpoint_path)
        self.tokenizer = spm.SentencePieceProcessor(model_file=str(tokenizer_path))
        self.max_length = self.model.maxlen
        self.checkpoint_path = checkpoint_path
        self.tokenizer_path = tokenizer_path
        expected = self.checkpoint.get("tokenizer_sha256")
        actual = hashlib.sha256(tokenizer_path.read_bytes()).hexdigest()
        if expected and expected != actual:
            raise ValueError("checkpoint/tokenizer SHA-256 mismatch")
        self.tokenizer_sha256 = actual
        self.stage = self.checkpoint.get("stage", "legacy")
        self.mode_id = self.tokenizer.piece_to_id("<en>")
        if self.mode_id < 0 or self.mode_id == self.tokenizer.unk_id():
            raise ValueError("tokenizer is missing the <en> mode symbol")
        if self.tokenizer.pad_id() < 0:
            raise ValueError("tokenizer is missing a pad token")

    def scores(self, words, context, normalize):
        if not words:
            return []
        torch = self.torch
        context_ids = [self.mode_id] + self.tokenizer.encode(
            " ".join(context).lower(), out_type=int
        )
        rows = []
        for word in words:
            pieces = self.tokenizer.encode(" " + word, out_type=int) \
                or [self.tokenizer.unk_id()]
            kept = context_ids[-max(1, self.max_length + 1 - len(pieces)):]
            full = (kept + pieces)[:self.max_length + 1]
            rows.append((full[:-1], full[1:], len(kept) - 1))
        inputs = torch.full(
            (len(rows), self.max_length), self.tokenizer.pad_id(), dtype=torch.long
        )
        for index, (tokens, _, _) in enumerate(rows):
            inputs[index, :len(tokens)] = torch.tensor(tokens, dtype=torch.long)
        with torch.inference_mode():
            log_probs = self.model(inputs).float().log_softmax(dim=-1)
        result = []
        for index, (_, labels, start) in enumerate(rows):
            values = [log_probs[index, position, labels[position]].item()
                      for position in range(start, len(labels))]
            total = sum(values)
            result.append(total / max(1, len(values)) if normalize else total)
        return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--dataset", type=Path,
                    help="real labelled JSONL; disables synthetic typo generation")
    ap.add_argument("--split", help="only evaluate this dataset split")
    ap.add_argument("--require-user-separated", action="store_true",
                    help="require user_id/split and reject users spanning splits")
    ap.add_argument("--output-json", type=Path,
                    help="write a machine-readable benchmark manifest")
    ap.add_argument("--neural", action="store_true")
    ap.add_argument("--checkpoint", type=Path,
                    help="legacy or 10.6M checkpoint; implies --neural")
    ap.add_argument("--tokenizer", type=Path,
                    help="matching SentencePiece model (defaults beside checkpoint)")
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
    triples = load_jsonl(args.dataset, args.split, args.require_user_separated) \
        if args.dataset else make_triples(ld, args.n, rng, args.edits)
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
    if not triples:
        raise ValueError("the selected benchmark slice contains no cases")

    if args.oracle:
        # Oracle recall = the hard ceiling on every downstream number: if the gold
        # word isn't in the candidate list, no rescorer at any size can save it.
        # Two stages can lose it: (1) the channel prune — pair cost > maxCost, the
        # word never comes out of the trie; (2) the crude pre-rank cap — it comes
        # out, but ranks below what survives to the rescorer (Swift keeps nBest=24
        # from a scoreCap=32 batch). Report both, plus what a bigger budget buys.
        ks = (3, 8, 12, 16, 24)
        budgets = (1.8, 2.8, 3.6, 4.0)
        n = len(triples)
        found, hit_at = 0, {k: 0 for k in ks}
        within = {b: 0 for b in budgets}
        within_dynamic = 0
        for typed, intended, ctx in triples:
            c = pair_cost(typed, intended)
            within_dynamic += c <= cost_budget(len(typed))
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
        tags = {24: "  <- Swift nBest"}
        for k in ks:
            print(f"  recall@{k:<2}  {hit_at[k] / n:.3f}{tags.get(k, '')}")
        print("channel-prune ceiling if maxCost were relaxed (exact pair-cost DP):")
        for b in budgets:
            print(f"  fixed maxCost {b}  {within[b] / n:.3f}")
        print(f"  shipped dynamic budget  {within_dynamic / n:.3f}")
        return

    neural = None
    if args.neural or args.sweep or args.checkpoint:
        checkpoint_path = args.checkpoint or (HERE / "data/lm.pt")
        tokenizer_path = args.tokenizer
        if tokenizer_path is None:
            adjacent = checkpoint_path.parent / "spm.model"
            tokenizer_path = adjacent if adjacent.exists() else HERE / "data/spm.model"
        neural = NeuralWordScorer(checkpoint_path, tokenizer_path)

    def capped_candidates(typed):
        generated = trie.search(typed)
        typed_id = ld.ids.get(typed)
        typed_frequency = math.log(ld.freqs[typed_id] + 1) if typed_id is not None else 0.0
        pool = list(generated)
        pool.sort(key=lambda row: -row[1] + FREQ_W * math.log1p(max(row[2], 0)),
                  reverse=True)
        typed_row = (typed, 0.0, typed_frequency)
        uncapped = pool if any(row[0] == typed for row in pool) else pool + [typed_row]
        capped = pool[:31]
        if not any(row[0] == typed for row in capped):
            capped.append(typed_row)
        return uncapped, capped

    def evaluate(weight, norm):
        # Cache neural scores per (word, ctx-id) so a sweep doesn't re-run the model.
        top1 = top3 = 0
        oracle_before_cap = oracle = false_corrections = correct_inputs = 0
        latencies_ms = []
        for ti, (typed, intended, ctx) in enumerate(triples):
            started = time.perf_counter_ns()
            scored = []
            generated, candidates = capped_candidates(typed)
            oracle_before_cap += any(word == intended for word, _, _ in generated)
            oracle += any(word == intended for word, _, _ in candidates)
            if neural and weight > 0:
                missing = [word for word, _, _ in candidates
                           if (word, ti, norm) not in cache]
                for word, value in zip(missing, neural.scores(missing, ctx, norm)):
                    cache[(word, ti, norm)] = value
            for w, cost, lf in candidates:
                prior = logprob(ld, w, ctx)
                if neural and weight > 0:
                    key = (w, ti, norm)
                    prior = weight * cache[key] + (1 - weight) * prior
                scored.append((-cost + LM_W * prior + FREQ_W * lf, w))
            scored.sort(reverse=True)
            ranked = [w for _, w in scored]
            latencies_ms.append((time.perf_counter_ns() - started) / 1_000_000)
            top1 += ranked[:1] == [intended]
            top3 += intended in ranked[:3]
            if typed == intended:
                correct_inputs += 1
                false_corrections += ranked[:1] != [intended]
        count = len(triples)
        return {
            "cases": count,
            "top1": top1 / count,
            "top3": top3 / count,
            "oracle_recall_before_cap": oracle_before_cap / count,
            "oracle_recall": oracle / count,
            "false_correction_cases": correct_inputs,
            "false_correction_rate": (false_corrections / correct_inputs
                                      if correct_inputs else None),
            "cpu_ms_per_case_p50": statistics.median(latencies_ms),
            "cpu_ms_per_case_p95": percentile(latencies_ms, 0.95),
        }

    cache: dict = {}
    if args.sweep:
        print(f"{'weight':>7} {'norm':>5} {'top-1':>6} {'top-3':>6}")
        baseline = evaluate(0.0, False)
        print(f"{'baseline':>7} {'—':>5} {baseline['top1']:>6.3f} {baseline['top3']:>6.3f}")
        for norm in (True, False):
            for weight in (0.3, 0.5, 0.7, 0.9):
                metrics = evaluate(weight, norm)
                print(f"{weight:>7.1f} {str(norm):>5} {metrics['top1']:>6.3f} {metrics['top3']:>6.3f}")
    else:
        metrics = evaluate(args.neural_weight if neural else 0.0, not args.no_norm)
        tag = (f"{neural.checkpoint_path.name}:{neural.stage}"
               if neural else "n-gram baseline")
        print(
            f"top-1 {metrics['top1']:.3f}   top-3 {metrics['top3']:.3f}   "
            f"oracle {metrics['oracle_recall']:.3f}   false-correction "
            f"{metrics['false_correction_rate']:.3f}   ({tag})"
            if metrics["false_correction_rate"] is not None else
            f"top-1 {metrics['top1']:.3f}   top-3 {metrics['top3']:.3f}   "
            f"oracle {metrics['oracle_recall']:.3f}   false-correction n/a "
            f"(no already-correct cases; {tag})"
        )
        if args.output_json:
            digest = hashlib.sha256(LANGDATA.read_bytes()).hexdigest()
            manifest = {
                "schema_version": 1,
                "generated_at_unix": int(time.time()),
                "source": str(args.dataset) if args.dataset else "synthetic-channel",
                "split": args.split,
                "seed": 7,
                "synthetic_edits": None if args.dataset else args.edits,
                "language_data_sha256": digest,
                "scorer": "modified-kneser-ney-fresh-install",
                "candidate_generator": "python-trie-approximation",
                "forced_gold_insertion": False,
                "model": tag,
                "checkpoint_sha256": (file_sha256(neural.checkpoint_path)
                                      if neural else None),
                "tokenizer_sha256": neural.tokenizer_sha256 if neural else None,
                "neural_weight": args.neural_weight if neural else 0.0,
                "score_cap": 32,
                "metrics": metrics,
                "limitations": [
                    "not an iPhone latency measurement",
                    "does not model production completion/context-injection policy",
                    "does not include personalization",
                ],
            }
            args.output_json.parent.mkdir(parents=True, exist_ok=True)
            args.output_json.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            print(f"wrote {args.output_json}")


if __name__ == "__main__":
    main()
