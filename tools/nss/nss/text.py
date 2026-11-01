"""Text -> sentences of words, exactly as the keyboard reads its left context.

`KeyboardViewController.contextWords` treats letters and the apostrophes ' U+2019 U+02BC
as word characters and everything else (digits, hyphens, punctuation, emoji) as a
separator. `.`, `!`, `?` and newlines end the sentence: the keyboard never shows the
model words from an earlier sentence, so training sequences are single sentences too.
The engine lowercases and the vocabulary is lowercase. NFKC applies per word, after
splitting, so a compatibility form such as U+2026 cannot invent a sentence end.
"""

from __future__ import annotations

import re
import unicodedata

SENTENCE_END = re.compile(r"[.!?\n]+")
# A letter is a word character that is neither a digit nor "_" (Unicode-aware).
WORD = re.compile(r"(?:[^\W\d_]|['’ʼ])+")
APOSTROPHES = str.maketrans({"’": "'", "ʼ": "'"})


def canonical(word: str) -> str:
    word = word.translate(APOSTROPHES)
    if not word.isascii():
        word = unicodedata.normalize("NFKC", word)
    return word.lower()


def words(fragment: str) -> list[str]:
    """Words of one sentence fragment, canonical apostrophes, lowercased.

    A run of apostrophes alone (a quotation mark between spaces) is not a word; the
    runtime skips such context words the same way.
    """
    return [canonical(match) for match in WORD.findall(fragment) if match.strip("'’ʼ")]


def cased_sentences(text: str) -> list[list[tuple[str, bool]]]:
    """sentences(text), each word paired with whether the source writes it capitalized: a
    capital first letter, not all capitals (a name or place inside a sentence, any
    sentence's first word; not OK, TV or the U of U.S.)."""
    def capitalized(match: str) -> bool:
        letters = match.strip("'’ʼ")
        return letters[:1].isupper() and not (len(letters) > 1 and letters.isupper()) and len(letters) > 1
    out = []
    for fragment in SENTENCE_END.split(text):
        found = [(canonical(match), capitalized(match)) for match in WORD.findall(fragment) if match.strip("'’ʼ")]
        if found:
            out.append(found)
    return out


def sentences(text: str) -> list[list[str]]:
    """Non-empty sentences of `text`, each a list of lowercase words."""
    out = []
    for fragment in SENTENCE_END.split(text):
        found = words(fragment)
        if found:
            out.append(found)
    return out
