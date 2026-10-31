"""Readers for the training/evaluation corpora. Each yields (split key, text) documents.

The split key decides train/valid/test (hash of the key), so every sentence of a
document lands in one split and an identical sentence repeated across documents of
one source lands in the same split.
"""

from __future__ import annotations

import bz2
import json
import re
from pathlib import Path
from typing import Iterator

from . import TOOLS

TATOEBA = TOOLS / "data" / "tatoeba-eng-2026-10-20.tsv.bz2"
WIKITEXT = [TOOLS / ".cache" / f"wikitext-103-raw-train-0000{i}-of-00002.parquet" for i in (0, 1)]
MASC_HELDOUT = TOOLS / "data" / "english-masc-heldout-v1.json.bz2"
# allenai/soda train split (CC BY 4.0): 1.19M synthetic everyday dialogues, the messaging register.
SODA = sorted((TOOLS / ".cache" / "soda-2026-10-31").glob("train-*.parquet"))

WIKI_ARTICLE = re.compile(r"^ = [^=].* = $")
WIKI_HEADING = re.compile(r"^ (= )+.*( =)+ $")
WIKI_CLITIC = re.compile(r"(\w) (n't|'s|'re|'ll|'ve|'m|'d)\b")
WIKI_ESCAPES = ((" @-@ ", "-"), (" @,@ ", ","), (" @.@ ", ""))


def tatoeba(path: Path = TATOEBA) -> Iterator[tuple[str, str]]:
    with bz2.open(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[2].strip():
                yield parts[2].strip(), parts[2]


def clean_wikitext(line: str) -> str:
    """Undo WikiText-103's Moses tokenization artifacts.

    `@.@` is a decimal point inside a number (digits are separators, so dropping it
    keeps "3 @.@ 5 million" one sentence); split clitics are re-attached.
    """
    for escape, replacement in WIKI_ESCAPES:
        line = line.replace(escape, replacement)
    return WIKI_CLITIC.sub(r"\1\2", line)


def wikitext(paths: list[Path] = WIKITEXT) -> Iterator[tuple[str, str]]:
    """Whole articles keyed by title; headings are dropped, paragraphs end sentences."""
    import pyarrow.parquet as pq

    title, paragraphs = None, []
    for path in paths:
        for line in pq.read_table(path, columns=["text"]).column(0).to_pylist():
            if WIKI_ARTICLE.match(line.rstrip("\n")):
                if title is not None and paragraphs:
                    yield title, "\n".join(paragraphs)
                title, paragraphs = line.strip(" =\n"), []
            elif line.strip() and not WIKI_HEADING.match(line.rstrip("\n")):
                paragraphs.append(clean_wikitext(line.strip()))
    if title is not None and paragraphs:
        yield title, "\n".join(paragraphs)


def soda(paths: list[Path] = SODA) -> Iterator[tuple[str, str]]:
    """One dialogue per document, keyed by its SODA index; each utterance is a message
    (a newline ends its last sentence, as a sent message does)."""
    import pyarrow.parquet as pq

    for path in paths:
        parquet = pq.ParquetFile(path)
        for group in range(parquet.num_row_groups):
            table = parquet.read_row_group(group, columns=["original_index", "dialogue"])
            for index, dialogue in zip(table.column(0).to_pylist(), table.column(1).to_pylist()):
                yield f"soda-{index}", "\n".join(dialogue)


def masc_heldout(path: Path = MASC_HELDOUT) -> Iterator[tuple[str, list[str | None], str]]:
    """Held-out MASC sentences (document, tokens, genre). None marks a token the
    vocabulary builder could not represent (digits, URLs); it is never a target."""
    payload = json.load(bz2.open(path, "rt", encoding="utf-8"))
    for sentence in payload["sentences"]:
        yield sentence["document"], sentence["tokens"], sentence["genre"]


def plain_text(path: Path) -> Iterator[tuple[str, str]]:
    """One message or paragraph per line (an optional chat corpus)."""
    opener = bz2.open if str(path).endswith(".bz2") else open
    with opener(path, "rt", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                yield line.strip(), line
