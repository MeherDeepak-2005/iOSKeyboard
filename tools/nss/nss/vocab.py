"""The fixed NSS output vocabulary: four specials, then the 30k words of the vocab TSV.

The vocabulary and the model's output layer are a pair: every checkpoint and export
records the TSV's SHA-256 and refuses a different file.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from pathlib import Path

from . import DEFAULT_VOCAB

SPECIALS = ("<pad>", "<unk>", "<bos>", "<eos>")
PAD, UNK, BOS, EOS = range(4)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


@dataclass
class Vocabulary:
    words: list[str]
    sha256: str
    path: Path
    index: dict[str, int] = field(init=False, repr=False)

    def __post_init__(self):
        if tuple(self.words[:4]) != SPECIALS:
            raise ValueError(f"{self.path}: ids 0-3 must be {SPECIALS}")
        self.index = {word: i for i, word in enumerate(self.words)}
        if len(self.index) != len(self.words):
            raise ValueError(f"{self.path}: duplicate words")

    @classmethod
    def from_words(cls, words: list[str]) -> "Vocabulary":
        """An in-memory vocabulary (test fixtures); its hash covers the words."""
        digest = hashlib.sha256("\n".join(words).encode("utf-8")).hexdigest()
        return cls(list(words), digest, Path("<memory>"))

    @classmethod
    def load(cls, path: Path = DEFAULT_VOCAB) -> "Vocabulary":
        path = Path(path)
        rows = path.read_text(encoding="utf-8").splitlines()
        if not rows or not rows[0].startswith("id\tword"):
            raise ValueError(f"{path}: expected an id/word header")
        words = []
        for expected, row in enumerate(rows[1:]):
            ident, word = row.split("\t")[:2]
            if int(ident) != expected:
                raise ValueError(f"{path}: id {ident} out of order")
            words.append(word)
        return cls(words, sha256(path), path)

    def __len__(self) -> int:
        return len(self.words)

    def exact(self, word: str) -> int:
        """Id of a candidate word as the lexicon spells it, else <unk>."""
        found = self.index.get(word)
        return found if found is not None and found >= 4 else UNK

    def id(self, word: str) -> int:
        """Id of a word read from text (training text, the keyboard's left context).

        Quotes around a word are punctuation, not part of it ('hello' -> hello); the
        C++ runtime applies the same rule to context words. Candidates use `exact`.
        """
        found = self.exact(word)
        if found == UNK and (stripped := word.strip("'")) != word:
            found = self.exact(stripped)
        return found

    def encode(self, words: list[str]) -> list[int]:
        return [self.id(word) for word in words]
