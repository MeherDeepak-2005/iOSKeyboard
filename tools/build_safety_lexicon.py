#!/usr/bin/env python3
"""Build keyboard/safety.kbguard from the project's reviewed safety policy.

The input is tools/data/safety_terms.tsv. It is intentionally project-authored:
the previous generator copied mutable third-party lists with no pinned revision or
documented license. The keyboard never blocks what a user types; these exact terms
are only removed from automatic suggestions and corrections.

Storing the list as one packed binary (24 B/entry + UTF-8 blob) instead of Swift
string literals keeps it off the heap and out of the compiled binary — the whole
point of moving profanity to a file.

KBGUARD1 format (little-endian), matched byte-for-byte by KBSafetyLexicon:
  header  magic "KBGUARD1"[8], u16 version=1, u16 entrySize=24, u32 count,
          u32 blobBytes, u32 reserved
  entry   u64 hash, u32 utf8Offset, u16 utf8Len, u8 langID, u8 actionID,
          u16 flags, u16 sourceID, u32 reserved      (sorted by hash asc, term asc)
  blob    normalized UTF-8 term bytes
Hash = FNV-1a-64 over the normalized UTF-8; normalization mirrors the Swift reader.
"""

import struct
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / "keyboard" / "safety.kbguard"
SOURCE = ROOT / "data" / "safety_terms.tsv"

MASK64 = (1 << 64) - 1
# action ids (see manifest): allow=0, demote=1, suppress_suggest=2, suppress_always=3
SUPPRESS = 2
LANG_EN, LANG_TE = 1, 2


def fnv1a64(s: str) -> int:
    h = 0xCBF29CE484222325
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x100000001B3) & MASK64
    return h


def normalize(term: str, lang: int) -> str:
    """Mirror KBSafetyLexicon.normalize: Telugu → NFC; English → casefold + curly
    apostrophes to ASCII + whitespace collapse (for ASCII terms casefold == the
    Swift width/case fold)."""
    if lang == LANG_TE or any("ఀ" <= c <= "౿" for c in term):
        return " ".join(unicodedata.normalize("NFC", term).split())
    s = term.replace("’", "'").replace("‘", "'").replace("`", "'").casefold()
    return " ".join(s.split())


def main():
    if not SOURCE.exists():
        raise SystemExit(f"missing reviewed safety policy: {SOURCE}")
    terms: dict[str, tuple[int, int]] = {}
    for line_number, raw in enumerate(SOURCE.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.partition("#")[0].strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 2 or parts[1] not in {"en", "te"}:
            raise SystemExit(f"invalid {SOURCE.name}:{line_number}: expected term<TAB>en|te")
        word, language = parts
        lang = LANG_TE if language == "te" else LANG_EN
        norm = normalize(word, lang)
        if not norm:
            continue
        terms[norm] = (lang, SUPPRESS)

    # Build sorted (hash, term) entries + blob.
    rows = sorted(((fnv1a64(t), t, lang, act) for t, (lang, act) in terms.items()),
                  key=lambda r: (r[0], r[1]))
    blob = bytearray()
    entries = []
    for h, term, lang, act in rows:
        b = term.encode("utf-8")
        entries.append((h, len(blob), len(b), lang, act))
        blob += b

    temporary = OUT.with_suffix(".kbguard.tmp")
    with temporary.open("wb") as f:
        f.write(b"KBGUARD1")
        f.write(struct.pack("<HHIII", 1, 24, len(entries), len(blob), 0))
        for h, off, ln, lang, act in entries:
            f.write(struct.pack("<QIHBBHHI", h, off, ln, lang, act, 0, 0, 0))
        f.write(blob)
    temporary.replace(OUT)

    print(f"wrote {OUT} ({OUT.stat().st_size} bytes): {len(entries)} reviewed terms")


if __name__ == "__main__":
    main()
