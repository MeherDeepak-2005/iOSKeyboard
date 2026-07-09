#!/usr/bin/env python3
"""Build keyboard/safety.kbguard — the memory-mapped profanity blocklist the
extension reads via KBSafetyLexicon (Keyboard.swift).

Merges:
  - the Google profanity list (Shidouuu/Google-profanity-words, ~451 en words)
  - every term already in the current safety.kbguard (preserves the LDNOOBW set
    and the Telugu entries, and their curated demote/suppress actions)

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
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CACHE = ROOT / ".cache"
OUT = ROOT.parent / "keyboard" / "safety.kbguard"
GOOGLE_URL = "https://raw.githubusercontent.com/Shidouuu/Google-profanity-words/master/list.txt"

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


def read_existing(path: Path) -> dict[str, tuple[int, int]]:
    """{normalized term: (langID, actionID)} from an existing kbguard, or {}."""
    if not path.exists():
        return {}
    d = path.read_bytes()
    if d[:8] != b"KBGUARD1":
        return {}
    ver, esz, count, _blobbytes, _reserved = struct.unpack_from("<HHIII", d, 8)
    base, blob = 24, 24 + count * esz
    out: dict[str, tuple[int, int]] = {}
    for i in range(count):
        _h, off, ln, lang, act, _flags, _src, _rr = struct.unpack_from("<QIHBBHHI", d, base + i * esz)
        term = d[blob + off:blob + off + ln].decode("utf-8")
        out[term] = (lang, act)
    return out


def main():
    CACHE.mkdir(exist_ok=True)
    google = CACHE / "google_profanity_list.txt"
    if not google.exists():
        print(f"downloading {GOOGLE_URL} ...")
        urllib.request.urlretrieve(GOOGLE_URL, google)

    # Existing terms first (keep their curated actions), then Google words.
    terms: dict[str, tuple[int, int]] = dict(read_existing(OUT))
    existing = len(terms)
    added = upgraded = 0
    for line in google.read_text(errors="replace").splitlines():
        w = line.strip()
        if not w:
            continue
        norm = normalize(w, LANG_EN)
        if not norm:
            continue
        if norm in terms:
            lang, act = terms[norm]
            if act < SUPPRESS:            # Google says it's bad → upgrade demote/allow to suppress
                terms[norm] = (lang, SUPPRESS)
                upgraded += 1
        else:
            terms[norm] = (LANG_EN, SUPPRESS)
            added += 1
    print(f"merged: {existing} existing, {added} new, {upgraded} upgraded to suppress")

    # Build sorted (hash, term) entries + blob.
    rows = sorted(((fnv1a64(t), t, lang, act) for t, (lang, act) in terms.items()),
                  key=lambda r: (r[0], r[1]))
    blob = bytearray()
    entries = []
    for h, term, lang, act in rows:
        b = term.encode("utf-8")
        entries.append((h, len(blob), len(b), lang, act))
        blob += b

    with OUT.open("wb") as f:
        f.write(b"KBGUARD1")
        f.write(struct.pack("<HHIII", 1, 24, len(entries), len(blob), 0))
        for h, off, ln, lang, act in entries:
            f.write(struct.pack("<QIHBBHHI", h, off, ln, lang, act, 0, 0, 0))
        f.write(blob)

    print(f"wrote {OUT} ({OUT.stat().st_size} bytes): {len(entries)} terms "
          f"({existing} existing + {added} new from Google)")


if __name__ == "__main__":
    main()
