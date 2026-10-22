"""Large-corpus bigram/trigram counting for build_language_data.py.

Sources (both pinned by SHA-256):
  - Tatoeba English, every sentence (CC BY 2.0 FR; includes the earlier CC0 subset),
    vendored under tools/data because the upstream export changes nightly.
  - WikiText-103 raw train split (CC BY-SA 3.0), fetched from a pinned Hugging Face
    revision into tools/.cache.

Tokens are lowercased [a-z'] runs. Sentence ends (. ! ? ; :), hyphens and dashes,
parentheses, double quotes, digits and words outside the vocabulary are hard
boundaries, so no adjacency is invented across them ("an all-star" is not "an all"). Counting
uses packed int64 keys (17 bits per word ID) in numpy chunks to stay within laptop RAM.
Context totals are measured BEFORE pruning so retained probabilities stay honest.
"""

import bz2
import re
from pathlib import Path

import numpy as np

ID_BITS = 17                      # 114k-word vocabulary < 131,072
ID_MASK = (1 << ID_BITS) - 1
CHUNK_TOKENS = 12_000_000
TOKEN = re.compile(r"[a-z']+|[0-9]+|[.!?;:\-\u2013\u2014()\"]")
BOUNDARY = -1
WIKI_CONTRACTION = re.compile(r"(\w) '(s|re|ll|ve|m|d|t)\b")
WIKI_ESCAPES = (" @-@ ", "-"), (" @,@ ", ","), (" @.@ ", ".")
# A hyphenated compound is one non-vocabulary unit: "an all-star" must not count "an all".
COMPOUND = re.compile(r"[a-z']+(?:-[a-z']+)+")


def _normalize(text: str) -> str:
    text = text.lower().replace("’", "'").replace("‘", "'").replace("`", "'")
    return COMPOUND.sub(" - ", text)


def tatoeba_lines(path: Path):
    with bz2.open(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t", 2)
            if len(fields) == 3 and fields[1] == "eng":
                yield fields[2]


def wikitext_lines(paths):
    import pyarrow.parquet as pq   # build-time only dependency
    for path in paths:
        parquet = pq.ParquetFile(path)
        for group in range(parquet.num_row_groups):
            for text in parquet.read_row_group(group, columns=["text"]).column("text").to_pylist():
                text = text.strip()
                if not text or text.startswith("="):     # blank lines and section headings
                    continue
                for old, new in WIKI_ESCAPES:
                    text = text.replace(old, new)
                yield WIKI_CONTRACTION.sub(r"\1'\2", text)


def _encode(lines, ids, out: list):
    """Append word IDs for each line, with BOUNDARY between non-adjacent tokens."""
    for line in lines:
        out.append(BOUNDARY)
        for token in TOKEN.findall(_normalize(line)):
            word = token.strip("'")
            out.append(ids.get(word, BOUNDARY) if word and word[0].isalpha() else BOUNDARY)
        if len(out) >= CHUNK_TOKENS:
            yield
    yield


def _merge(keys, counts, new_keys, new_counts):
    if keys is None:
        return new_keys, new_counts
    joined = np.concatenate([keys, new_keys])
    unique, inverse = np.unique(joined, return_inverse=True)
    merged = np.bincount(inverse, weights=np.concatenate([counts, new_counts]).astype(np.float64))
    return unique, merged.astype(np.int64)


def count(sources, ids):
    """Return sorted (keys, counts) for bigrams and trigrams over all source line iterators."""
    bi_keys = bi_counts = tri_keys = tri_counts = None
    tokens = 0
    for lines in sources:
        buffer: list[int] = []
        for _ in _encode(lines, ids, buffer):
            if len(buffer) < 3:
                continue
            stream = np.asarray(buffer, dtype=np.int64)
            tokens += int((stream >= 0).sum())
            buffer.clear(); buffer.append(BOUNDARY)
            a, b, c = stream[:-2], stream[1:-1], stream[2:]
            ok = (stream[:-1] >= 0) & (stream[1:] >= 0)
            k, n = np.unique((stream[:-1][ok] << ID_BITS) | stream[1:][ok], return_counts=True)
            bi_keys, bi_counts = _merge(bi_keys, bi_counts, k, n)
            ok = (a >= 0) & (b >= 0) & (c >= 0)
            k, n = np.unique((a[ok] << (2 * ID_BITS)) | (b[ok] << ID_BITS) | c[ok], return_counts=True)
            tri_keys, tri_counts = _merge(tri_keys, tri_counts, k, n)
    return tokens, (bi_keys, bi_counts), (tri_keys, tri_counts)


def prune(keys, counts, min_count, per_context):
    """Context totals over ALL counts; keep entries >= min_count, top per_context by count."""
    contexts = keys >> ID_BITS
    starts = np.flatnonzero(np.r_[True, contexts[1:] != contexts[:-1]])
    totals = dict(zip(contexts[starts].tolist(), np.add.reduceat(counts, starts).tolist()))
    keep = counts >= min_count
    keys, counts, contexts = keys[keep], counts[keep], contexts[keep]
    order = np.lexsort((keys & ID_MASK, -counts, contexts))        # context, count desc, word ID
    keys, counts, contexts = keys[order], counts[order], contexts[order]
    starts = np.flatnonzero(np.r_[True, contexts[1:] != contexts[:-1]])
    rank = np.arange(len(keys)) - np.repeat(starts, np.diff(np.r_[starts, len(keys)]))
    keep = rank < per_context
    keys, counts, contexts = keys[keep], counts[keep], contexts[keep]
    table = {}
    starts = np.flatnonzero(np.r_[True, contexts[1:] != contexts[:-1]]) if len(keys) else []
    bounds = np.r_[starts, len(keys)] if len(keys) else []
    words, values, ctx = (keys & ID_MASK).tolist(), counts.tolist(), contexts.tolist()
    for i in range(len(starts)):
        s, e = int(bounds[i]), int(bounds[i + 1])
        table[ctx[s]] = list(zip(words[s:e], values[s:e]))
    return table, {k: totals[k] for k in table}


def split_trigram_context(packed: int) -> tuple[int, int]:
    return packed >> ID_BITS, packed & ID_MASK
