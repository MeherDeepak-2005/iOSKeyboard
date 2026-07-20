#!/usr/bin/env python3
"""Build keyboard/safety.kbguard from pinned and project-reviewed policy inputs.

The English baseline is vendored from coffee-and-fun/google-profanity-words at a
pinned commit and verified before every build. It is merged with the recovered and
project-reviewed TSVs. Candidate-only Telugu/Tenglish rows remain reviewable in
source control but cannot enter this artifact. The keyboard never blocks what a
user types; these exact terms affect generated suggestions, corrections, Glide,
learning, and neural candidates only.

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

import csv
import hashlib
import struct
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT.parent / "keyboard" / "safety.kbguard"
CURATED_SOURCE = ROOT / "data" / "safety_terms.tsv"
RECOVERED_SOURCE = ROOT / "data" / "safety_recovered_reviewed.tsv"
T_ENGLISH_SOURCE = ROOT / "data" / "safety_tenglish_candidates.tsv"
GOOGLE_EN_SOURCE = ROOT / "data" / "google_profanity_en.txt"
GOOGLE_EN_COMMIT = "0ae3460863120bc671361b9403cc65d5f2075b89"
GOOGLE_EN_SHA256 = "ea16a22f12b4fb9d32747b8fc7af21b90ce59df7313f6275ce1ef17d746b0dfe"

MASK64 = (1 << 64) - 1
# action ids (see manifest): allow=0, demote=1, suppress_suggest=2, suppress_always=3
ACTIONS = {"allow": 0, "demote": 1, "suppress_suggest": 2, "suppress_always": 3}
SUPPRESS = ACTIONS["suppress_suggest"]
LANGUAGES = {"en": 1, "te": 2, "tenglish": 3}
LANG_EN, LANG_TE, LANG_TENGLISH = 1, 2, 3
# Source bit flags stored in the existing u16 sourceID field. A merged term can
# carry both flags without changing the runtime format.
SOURCE_GOOGLE_EN, SOURCE_PROJECT, SOURCE_RECOVERED, SOURCE_TENGLISH = 1, 2, 4, 8


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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def merge_term(
    terms: dict[str, tuple[int, int, int]],
    term: str,
    lang: int,
    source_id: int,
    action: int = SUPPRESS,
) -> None:
    norm = normalize(term, lang)
    if not norm:
        return
    previous = terms.get(norm)
    if previous is None:
        terms[norm] = (lang, action, source_id)
        return
    old_lang, old_action, old_source = previous
    if old_lang != lang:
        raise SystemExit(f"normalized safety term has conflicting languages: {norm!r}")
    terms[norm] = (lang, max(old_action, action), old_source | source_id)


def read_policy_tsv(path: Path, source_id: int):
    if not path.exists():
        raise SystemExit(f"missing reviewed safety policy: {path}")
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        expected = {"term", "language", "action", "source", "license", "review_status"}
        if set(reader.fieldnames or ()) != expected:
            raise SystemExit(
                f"invalid {path.name} header: expected tab-separated {sorted(expected)}"
            )
        for line_number, row in enumerate(reader, 2):
            term = (row["term"] or "").strip()
            language = (row["language"] or "").strip()
            action = (row["action"] or "").strip()
            source = (row["source"] or "").strip()
            license_name = (row["license"] or "").strip()
            review = (row["review_status"] or "").strip()
            if not term or language not in LANGUAGES or action not in ACTIONS:
                raise SystemExit(f"invalid {path.name}:{line_number}")
            if not source or not license_name or review not in {"approved", "candidate", "rejected"}:
                raise SystemExit(f"missing provenance/review in {path.name}:{line_number}")
            # Candidate and rejected rows remain reviewable in source control but never
            # become runtime policy. In particular, no unreviewed suppress action ships.
            if review != "approved" or action == "allow":
                continue
            yield term, LANGUAGES[language], source_id, ACTIONS[action]


def main():
    if not GOOGLE_EN_SOURCE.exists():
        raise SystemExit(f"missing pinned English safety source: {GOOGLE_EN_SOURCE}")
    actual_sha = sha256(GOOGLE_EN_SOURCE)
    if actual_sha != GOOGLE_EN_SHA256:
        raise SystemExit(
            "refusing unreviewed English safety source: "
            f"expected {GOOGLE_EN_SHA256}, got {actual_sha}"
        )
    terms: dict[str, tuple[int, int, int]] = {}
    for raw in GOOGLE_EN_SOURCE.read_text(encoding="utf-8").splitlines():
        merge_term(terms, raw.strip(), LANG_EN, SOURCE_GOOGLE_EN)

    for path, source_id in (
        (RECOVERED_SOURCE, SOURCE_RECOVERED),
        (CURATED_SOURCE, SOURCE_PROJECT),
        (T_ENGLISH_SOURCE, SOURCE_TENGLISH),
    ):
        for word, language, row_source, action in read_policy_tsv(path, source_id):
            merge_term(terms, word, language, row_source, action)

    # Build sorted (hash, term) entries + blob.
    rows = sorted(((fnv1a64(t), t, lang, act, source_id)
                   for t, (lang, act, source_id) in terms.items()),
                  key=lambda r: (r[0], r[1]))
    blob = bytearray()
    entries = []
    for h, term, lang, act, source_id in rows:
        b = term.encode("utf-8")
        if len(b) > 0xFFFF:
            raise SystemExit(f"safety term is too long for KBGUARD1: {term!r}")
        entries.append((h, len(blob), len(b), lang, act, source_id))
        blob += b
    if len(blob) > 0xFFFFFFFF:
        raise SystemExit("safety term blob is too large for KBGUARD1")

    temporary = OUT.with_suffix(".kbguard.tmp")
    with temporary.open("wb") as f:
        f.write(b"KBGUARD1")
        f.write(struct.pack("<HHIII", 1, 24, len(entries), len(blob), 0))
        for h, off, ln, lang, act, source_id in entries:
            f.write(struct.pack("<QIHBBHHI", h, off, ln, lang, act, 0, source_id, 0))
        f.write(blob)
    temporary.replace(OUT)

    print(
        f"wrote {OUT} ({OUT.stat().st_size} bytes): {len(entries)} exact terms; "
        f"English source pinned at {GOOGLE_EN_COMMIT}"
    )


if __name__ == "__main__":
    main()
