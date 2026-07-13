#!/usr/bin/env python3
"""Build the bundled language data for the keyboard extension.

Produces keyboard/langdata.bin — ONE little-endian binary the extension
memory-maps at launch. mmap means the n-gram tables never become Swift
dictionaries on the heap: the pages are clean/file-backed, the OS evicts them
under pressure, and they barely count against the extension's ~60-70 MB kill
limit (dirty heap counts fully; mapped read-only file pages effectively don't).

FORMAT v3 — v2's open-addressing hash tables plus a STATIC TRIE section, so the
Swift side can run its fuzzy-search DP and prefix completions directly over the
mapped file instead of materializing a ~60k-word heap trie at every keyboard
launch (that trie was most of the extension's fixed dirty footprint). Context
lookup (bigram: word id; trigram: word-id pair) stays O(1) expected — one
splitmix64 hash + a short linear probe. The Swift reader (LangData in
Keyboardengine.swift) and the eval-harness mirror this format identically.

Layout (all fields u32 LE unless noted; entry ranges are [start, start+count)):

  header   magic 'KBLM', version=3, W, biBuckets, BE, triBuckets, TE, trieNodes
  freq     u32 x W                                 word frequencies, id = index
  offsets  u32 x (W+1)                             byte offsets into blob, per id
  biHash   (ctx, total, entStart, entCount) x biBuckets    empty slot: ctx=0xFFFFFFFF
  biEnt    (word, count) x BE                      per-ctx, count desc
  triHash  (w1, w2, total, entStart, entCount) x triBuckets  empty slot: w1=0xFFFFFFFF
  triEnt   (word, count) x TE
  trie     (label u8, childCount u8, firstChild u32, wordID u32, maxFreq u32)
           x trieNodes — 14 B packed. BFS order, node 0 = root (label 0);
           children contiguous from firstChild, sorted by label byte;
           wordID 0xFFFFFFFF = not a word; maxFreq = max corpus frequency in
           the node's subtree, so top-k completion is a best-first walk that
           emits words in exact frequency order without visiting the subtree.
  blob     utf8 word bytes

`total` is the TRUE context total (pre-truncation) so probabilities stay honest
even though only the top predictions per context are kept.

Sources:
  - Vocabulary (the trie dictionary + id space): hermitdave/FrequencyWords
    (OpenSubtitles 2018) — a broad, conversational 60k word list. Kept large so
    autocorrect has good coverage of valid words.
  - Bi/trigram TABLES: our own tools/lm/data/corpus.txt (SMS + DailyDialog +
    OpenSubtitles + Leipzig, register-tagged). Counting context from the same
    messaging-register corpus the LM trains on — not Norvig web bigrams / Leipzig
    news trigrams — is the "improve the n-gram model" change.

Downloads are cached in tools/.cache/ (gitignored). Re-run any time.
"""

import re
import struct
import sys
import urllib.request
from collections import Counter, defaultdict, deque
from pathlib import Path

DICT_URL = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_full.txt"

DICT_SIZE = 60_000
MIN_WORD_FREQ = 5          # drop one-off OCR/subtitle junk from the long tail
BI_PER_CTX = 32            # predictions per context worth keeping
TRI_PER_CTX = 16
TRI_MIN_COUNT = 3          # a trigram seen twice in the corpus is noise
STARTERS_KEEP = 256        # sentence-initial words kept for the cold-start bar
CONTRACTIONS_KEEP = 300    # corpus-harvested interior-apostrophe words merged into vocab
CONTRACTIONS_MIN = 100     # min corpus count — below this it's a typo, not a contraction
HASH_LOAD = 0.7            # hash-table load factor (buckets = nextPow2(n / load))
EMPTY = 0xFFFFFFFF         # empty-bucket sentinel (word ids are < DICT_SIZE)

# Informal apostrophe-less forms frequent in the subtitle corpus. If these ship
# as vocabulary words the engine can never correct them (dictionary words are
# never corrected) — stock corrects dont->don't, im->I'm, so we must too. Real
# words that merely look like these (ill, id, its, hell, well, shed...) stay.
EXCLUDE = {
    "im", "dont", "cant", "wont", "aint", "didnt", "doesnt", "isnt", "wasnt",
    "arent", "werent", "wouldnt", "couldnt", "shouldnt", "havent", "hasnt",
    "hadnt", "youre", "theyre", "youve", "weve", "theyve", "youll", "youd",
    "whats", "thats", "heres", "theres", "wheres", "hes", "shes", "lets",
}

WORD = re.compile(r"^[a-z']+$")
TOKEN = re.compile(r"[a-z']+")
ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
CORPUS = ROOT / "lm" / "data" / "corpus.txt"
OUT = ROOT.parent / "keyboard" / "langdata.bin"

MASK64 = (1 << 64) - 1


def fetch(url: str, cache_name: str) -> Path:
    CACHE.mkdir(exist_ok=True)
    path = CACHE / cache_name
    if not path.exists():
        print(f"downloading {url} ...", flush=True)
        urllib.request.urlretrieve(url, path)
    return path


def build_vocab() -> list[tuple[str, int]]:
    vocab: list[tuple[str, int]] = []
    seen: set[str] = set()
    for line in fetch(DICT_URL, "en_full.txt").read_text(errors="replace").splitlines():
        parts = line.split()
        if len(parts) != 2 or not parts[1].isdigit():
            continue
        w, freq = parts[0], int(parts[1])
        if freq < MIN_WORD_FREQ or not WORD.match(w):
            continue
        if len(w) == 1 and w not in ("a", "i"):
            continue                     # stray single letters aren't words
        if w in EXCLUDE or w.startswith("'") or w.endswith("'") or w in seen:
            continue
        seen.add(w)
        vocab.append((w, min(freq, 0xFFFFFFFF)))
        if len(vocab) >= DICT_SIZE:
            break
    return vocab


def build_ngrams(ids: dict[str, int]):
    """Count bi/trigrams AND sentence starters over corpus.txt (messaging register).

    Starters = the first in-vocab word of each line. This is the fix for cold-start
    suggestions: ranking the empty-context bar by GLOBAL frequency surfaces mid-sentence
    function words (and, of, to) that almost never open a message. Sentence-initial
    counts instead surface openers — i, the, i'm, you, what — the way stock keyboards do.
    NOT TF/IDF: that would wrongly suppress 'the', which is a fine opener."""
    if not CORPUS.exists():
        sys.exit(f"missing {CORPUS} — run tools/lm/prepare_data.py first")
    by_ctx_bi: dict[int, Counter] = defaultdict(Counter)
    tri_counts: Counter = Counter()
    starter_counts: Counter = Counter()
    print(f"counting bi/trigrams + starters over {CORPUS.name} ...", flush=True)
    with CORPUS.open(errors="replace") as f:
        for line in f:
            toks = line.split()
            if toks and toks[0].startswith("<"):        # drop the register tag
                toks = toks[1:]
            ti = [ids[t] for t in toks if t in ids]
            if ti:
                starter_counts[ti[0]] += 1              # first word of the sentence
            for i in range(len(ti) - 1):
                by_ctx_bi[ti[i]][ti[i + 1]] += 1
            for i in range(len(ti) - 2):
                tri_counts[(ti[i], ti[i + 1], ti[i + 2])] += 1
    bigrams = {c: cnt.most_common() for c, cnt in by_ctx_bi.items()}
    by_ctx_tri: dict[tuple[int, int], list[tuple[int, int]]] = defaultdict(list)
    for (a, b, c), n in tri_counts.items():
        if n >= TRI_MIN_COUNT:
            by_ctx_tri[(a, b)].append((c, n))
    trigrams = {k: sorted(v, key=lambda e: -e[1]) for k, v in by_ctx_tri.items()}
    starters = [(w, n) for w, n in starter_counts.most_common(STARTERS_KEEP)]
    return bigrams, trigrams, starters


def next_pow2(n: int) -> int:
    p = 1
    while p < n:
        p <<= 1
    return p


def mix64(x: int) -> int:
    """splitmix64 finalizer — must match LangData.mix64 in Swift/Python readers."""
    x &= MASK64
    x ^= x >> 30
    x = (x * 0xBF58476D1CE4E5B9) & MASK64
    x ^= x >> 27
    x = (x * 0x94D049BB133111EB) & MASK64
    x ^= x >> 31
    return x


def build_table(rows: list[tuple], key_of) -> tuple[int, list]:
    """Open-addressing (linear-probe) hash table over `rows`. Returns (buckets, table)
    where table[b] is a row tuple or None (empty)."""
    buckets = max(1, next_pow2(int(len(rows) / HASH_LOAD) + 1))
    table: list = [None] * buckets
    for row in rows:
        b = mix64(key_of(row)) & (buckets - 1)
        while table[b] is not None:
            b = (b + 1) & (buckets - 1)
        table[b] = row
    return buckets, table


def build_trie(vocab) -> list[list[int]]:
    """Static trie over the vocab, serialized as BFS records (see header doc)."""

    class N:
        __slots__ = ("kids", "wid")

        def __init__(self):
            self.kids: dict[int, N] = {}
            self.wid = EMPTY

    root = N()
    for i, (w, _) in enumerate(vocab):
        node = root
        for b in w.encode():
            nxt = node.kids.get(b)
            if nxt is None:
                nxt = N()
                node.kids[b] = nxt
            node = nxt
        node.wid = i

    # Subtree max frequency, post-order (explicit stack — no recursion limits).
    maxfreq: dict[int, int] = {}
    stack: list[tuple[N, bool]] = [(root, False)]
    while stack:
        node, done = stack.pop()
        if done:
            m = vocab[node.wid][1] if node.wid != EMPTY else 0
            for c in node.kids.values():
                m = max(m, maxfreq[id(c)])
            maxfreq[id(node)] = m
        else:
            stack.append((node, True))
            for c in node.kids.values():
                stack.append((c, False))

    # BFS serialization: each node's children form one contiguous, label-sorted
    # block, so the reader walks [firstChild, firstChild+childCount).
    records: list[list[int]] = [[0, 0, 0, root.wid, maxfreq[id(root)]]]
    queue = deque([(0, root)])
    while queue:
        idx, node = queue.popleft()
        kids = sorted(node.kids.items())
        records[idx][1] = len(kids)
        records[idx][2] = len(records) if kids else 0
        for label, child in kids:
            ci = len(records)
            records.append([label, 0, 0, child.wid, maxfreq[id(child)]])
            queue.append((ci, child))
    return records


def write_bin(vocab, bigrams, trigrams, starters) -> None:
    blob = bytearray()
    offsets = [0]
    for w, _ in vocab:
        blob += w.encode()
        offsets.append(len(blob))

    # Entry arrays + per-context (ctx.., total, entStart, entCount) rows.
    bi_rows, bi_ent = [], []
    for ctx, ent in bigrams.items():
        total = sum(c for _, c in ent)
        kept = ent[:BI_PER_CTX]
        bi_rows.append((ctx, min(total, 0xFFFFFFFF), len(bi_ent), len(kept)))
        bi_ent += [(w, min(c, 0xFFFFFFFF)) for w, c in kept]

    tri_rows, tri_ent = [], []
    for (a, b), ent in trigrams.items():
        total = sum(c for _, c in ent)
        kept = ent[:TRI_PER_CTX]
        tri_rows.append((a, b, min(total, 0xFFFFFFFF), len(tri_ent), len(kept)))
        tri_ent += [(w, min(c, 0xFFFFFFFF)) for w, c in kept]

    bi_buckets, bi_table = build_table(bi_rows, key_of=lambda r: r[0])
    tri_buckets, tri_table = build_table(tri_rows, key_of=lambda r: (r[0] << 32) | r[1])
    trie = build_trie(vocab)

    with OUT.open("wb") as f:
        # v4 = v3 + a sentence-starters section (starterCount in the header, an array of
        # (wordId, count) sorted by count desc, placed between the trie and the blob).
        f.write(struct.pack("<9I", 0x4B424C4D, 4, len(vocab),
                            bi_buckets, len(bi_ent), tri_buckets, len(tri_ent), len(trie),
                            len(starters)))
        f.write(struct.pack(f"<{len(vocab)}I", *(c for _, c in vocab)))
        f.write(struct.pack(f"<{len(offsets)}I", *offsets))
        for row in bi_table:
            f.write(struct.pack("<4I", *(row if row else (EMPTY, 0, 0, 0))))
        for row in bi_ent:
            f.write(struct.pack("<2I", *row))
        for row in tri_table:
            f.write(struct.pack("<5I", *(row if row else (EMPTY, 0, 0, 0, 0))))
        for row in tri_ent:
            f.write(struct.pack("<2I", *row))
        for rec in trie:
            f.write(struct.pack("<BBIII", *rec))
        for w, n in starters:
            f.write(struct.pack("<2I", w, min(n, 0xFFFFFFFF)))
        f.write(blob)
    mb = OUT.stat().st_size / 1e6
    top = ", ".join(vocab[w][0] for w, _ in starters[:6])
    print(f"wrote {OUT} ({mb:.1f} MB): {len(vocab)} words, "
          f"{len(bi_ent)} bigrams/{len(bi_rows)} ctx ({bi_buckets} buckets), "
          f"{len(tri_ent)} trigrams/{len(tri_rows)} ctx ({tri_buckets} buckets), "
          f"{len(trie)} trie nodes, {len(starters)} starters [{top} ...]")


def merge_contractions(vocab: list[tuple[str, int]]) -> list[tuple[str, int]]:
    """The FrequencyWords source strips apostrophes, so the vocab ships with ZERO
    contractions — autocorrect can't produce "don't" and glide can't decode "what's"
    (EXCLUDE removed the apostrophe-less forms expecting the real ones to exist).
    Harvest interior-apostrophe tokens from our own corpus, scale their counts onto
    the vocab's frequency scale (via anchor words present in both), and merge."""
    if not CORPUS.exists():
        sys.exit(f"missing {CORPUS} — run tools/lm/prepare_data.py first")
    pat = re.compile(r"^[a-z]+'[a-z]+$")
    counts: Counter = Counter()
    anchors = {"you": 0, "the": 0, "and": 0, "that": 0}
    print("harvesting contractions from corpus ...", flush=True)
    with CORPUS.open(errors="replace") as f:
        for line in f:
            for tok in line.split():
                if tok in anchors:
                    anchors[tok] += 1
                elif "'" in tok and pat.match(tok):
                    counts[tok] += 1
    vfreq = dict(vocab)
    ratios = [vfreq[w] / c for w, c in anchors.items() if c > 0 and w in vfreq]
    scale = sum(ratios) / len(ratios) if ratios else 1.0
    have = set(vfreq)
    added = [(w, min(int(c * scale), 0xFFFFFFFF))
             for w, c in counts.most_common(CONTRACTIONS_KEEP)
             if c >= CONTRACTIONS_MIN and w not in have]
    merged = sorted(vocab + added, key=lambda e: -e[1])   # keep "earlier id = more frequent"
    top = ", ".join(w for w, _ in added[:8])
    print(f"contractions: +{len(added)} merged (scale x{scale:.0f}) [{top} ...]")
    return merged


if __name__ == "__main__":
    if not OUT.parent.is_dir():
        sys.exit(f"expected keyboard/ folder at {OUT.parent}")
    vocab = merge_contractions(build_vocab())
    ids = {w: i for i, (w, _) in enumerate(vocab)}
    print(f"vocab: {len(vocab)} words")
    write_bin(vocab, *build_ngrams(ids))
