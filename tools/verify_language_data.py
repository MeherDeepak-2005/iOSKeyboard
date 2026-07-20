#!/usr/bin/env python3
"""Compare two langdata packs by logical content, independent of file format."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

MAGIC = 0x4B424C4D
EMPTY32 = 0xFFFFFFFF
EMPTY16 = 0xFFFF


class Pack:
    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        magic, self.version, self.words, self.bi_contexts, self.bi_entries, \
            self.tri_contexts, self.tri_entries, self.trie_nodes, self.starters = \
            struct.unpack_from("<9I", self.data, 0)
        if magic != MAGIC or self.version not in (4, 5):
            raise ValueError(f"{path}: expected langdata v4 or v5")
        self.freq_base = 36
        self.offsets_base = self.freq_base + 4 * self.words
        self.bi_base = self.offsets_base + 4 * (self.words + 1)
        compact = self.version == 5
        self.entry_size = 6 if compact else 8
        self.node_size = 12 if compact else 14
        self.starter_size = 6 if compact else 8
        self.bi_entries_base = self.bi_base + (12 if compact else 16) * self.bi_contexts
        self.tri_base = self.bi_entries_base + self.entry_size * self.bi_entries
        self.tri_entries_base = self.tri_base + (12 if compact else 20) * self.tri_contexts
        self.trie_base = self.tri_entries_base + self.entry_size * self.tri_entries
        self.starters_base = self.trie_base + self.node_size * self.trie_nodes
        self.blob_base = self.starters_base + self.starter_size * self.starters
        if self.blob_base > len(self.data):
            raise ValueError(f"{path}: truncated section table")

    def vocabulary(self):
        frequencies = struct.unpack_from(f"<{self.words}I", self.data, self.freq_base)
        offsets = struct.unpack_from(f"<{self.words + 1}I", self.data, self.offsets_base)
        words = tuple(self.data[self.blob_base + offsets[i]:self.blob_base + offsets[i + 1]]
                      for i in range(self.words))
        return words, frequencies

    def entries(self, base: int, start: int, count: int):
        fmt = "<HI" if self.version == 5 else "<II"
        return tuple(struct.unpack_from(fmt, self.data, base + self.entry_size * index)
                     for index in range(start, start + count))

    def bigrams(self):
        output = {}
        if self.version == 5:
            for index in range(self.bi_contexts):
                ctx, count, total, start = struct.unpack_from(
                    "<HHII", self.data, self.bi_base + 12 * index)
                output[ctx] = (total, self.entries(self.bi_entries_base, start, count))
        else:
            for index in range(self.bi_contexts):
                ctx, total, start, count = struct.unpack_from(
                    "<IIII", self.data, self.bi_base + 16 * index)
                if ctx != EMPTY32:
                    output[ctx] = (total, self.entries(self.bi_entries_base, start, count))
        return output

    def trigrams(self):
        output = {}
        if self.version == 5:
            starts = [struct.unpack_from("<I", self.data, self.tri_base + 12 * i + 8)[0]
                      for i in range(self.tri_contexts)] + [self.tri_entries]
            for index in range(self.tri_contexts):
                key, total, start = struct.unpack_from(
                    "<III", self.data, self.tri_base + 12 * index)
                output[key] = (total, self.entries(
                    self.tri_entries_base, start, starts[index + 1] - start))
        else:
            for index in range(self.tri_contexts):
                w1, w2, total, start, count = struct.unpack_from(
                    "<IIIII", self.data, self.tri_base + 20 * index)
                if w1 != EMPTY32:
                    output[(w1 << 16) | w2] = (
                        total, self.entries(self.tri_entries_base, start, count))
        return output

    def trie(self):
        records = []
        for index in range(self.trie_nodes):
            offset = self.trie_base + self.node_size * index
            if self.version == 5:
                label, children, first, word, maximum = struct.unpack_from(
                    "<BBIHI", self.data, offset)
                word = EMPTY32 if word == EMPTY16 else word
            else:
                label, children, first, word, maximum = struct.unpack_from(
                    "<BBIII", self.data, offset)
            records.append((label, children, first, word, maximum))
        return tuple(records)

    def sentence_starters(self):
        fmt = "<HI" if self.version == 5 else "<II"
        return tuple(struct.unpack_from(fmt, self.data,
            self.starters_base + self.starter_size * index) for index in range(self.starters))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--max-bytes", type=int, default=11_000_000)
    args = parser.parse_args()
    old, new = Pack(args.reference), Pack(args.candidate)
    checks = {
        "vocabulary/frequencies": old.vocabulary() == new.vocabulary(),
        "bigrams": old.bigrams() == new.bigrams(),
        "trigrams": old.trigrams() == new.trigrams(),
        "trie": old.trie() == new.trie(),
        "sentence starters": old.sentence_starters() == new.sentence_starters(),
        "candidate size": len(new.data) <= args.max_bytes,
    }
    failures = [name for name, passed in checks.items() if not passed]
    if failures:
        raise SystemExit("language-data verification failed: " + ", ".join(failures))
    print(f"verified v{old.version} -> v{new.version}: all logical records identical")
    print(f"size: {len(old.data):,} -> {len(new.data):,} bytes "
          f"({(1 - len(new.data) / len(old.data)) * 100:.1f}% smaller)")
    print(f"sha256: {digest(args.candidate)}")


if __name__ == "__main__":
    main()
