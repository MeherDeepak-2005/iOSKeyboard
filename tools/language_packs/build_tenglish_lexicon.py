#!/usr/bin/env python3
"""Build a deterministic, memory-mappable Tenglish research lexicon.

Only the Aksharantar *training* split may be compiled. Validation and test files
remain untouched release measurements. The output stays research-only until a
weighted transliteration FST, Telugu LM, safety data, native review, and blind
benchmark are added to the same manifest.
"""

from __future__ import annotations

import argparse
import collections
import csv
import hashlib
import json
import math
import re
import sqlite3
import struct
import tempfile
import unicodedata
import zipfile
from pathlib import Path

from ngram_compaction import compact_contexts

MAGIC = b"KBXL"
VERSION = 2
VERSION_WITH_LM = 3
HEADER = struct.Struct("<4s7I")
HEADER_WITH_LM = struct.Struct("<4s15I")
# v2 removes two runtime-unused Float/UInt32 padding fields while preserving every
# key, variant weight, and source-provenance bit: 12 bytes per record instead of 16.
KEY_RECORD = struct.Struct("<IHHI")
VARIANT_RECORD = struct.Struct("<IHHf")
BIGRAM_CONTEXT = struct.Struct("<HII")
TRIGRAM_CONTEXT = struct.Struct("<III")
CONTINUATION = struct.Struct("<HI")
DEFAULT_BIGRAM_BYTE_BUDGET = 48 * 1024
DEFAULT_TRIGRAM_BYTE_BUDGET = 48 * 1024
DEFAULT_MAX_CONTINUATIONS = 12
ROMAN_START_CONTEXT = 0xFFFF
ROMAN = re.compile(r"^[a-z']{2,48}$")
SOURCE_BITS = {
    "Dakshina": 1 << 0,
    "IndicCorp": 1 << 1,
    "Samanantar": 1 << 2,
    "Wikidata": 1 << 3,
    "Existing": 1 << 4,
    "AK-NEI": 1 << 5,
    "AK-NEF": 1 << 6,
    "Ak-Uni": 1 << 7,
    "Ak-Freq": 1 << 8,
    "ProjectCore": 1 << 9,
}
SOURCE_PRIOR = {
    "Dakshina": 5.0,
    "Ak-Freq": 4.0,
    "ProjectCore": 9.0,
    "Existing": 3.5,
    "Ak-Uni": 3.0,
    "IndicCorp": 2.5,
    "Samanantar": 2.5,
    "Wikidata": 2.0,
    "AK-NEI": 1.0,
    "AK-NEF": 0.5,
}
DATASET_URL = "https://huggingface.co/datasets/ai4bharat/Aksharantar"
LICENSE_URL = DATASET_URL + "#licensing-information"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize_roman(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    value = unicodedata.normalize("NFKC", value).strip().lower()
    value = value.replace("’", "'").replace("‘", "'").replace("`", "'")
    if any(character.isspace() for character in value):
        return None
    value = value.strip("'")
    return value if ROMAN.fullmatch(value) else None


def normalize_telugu(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    value = unicodedata.normalize("NFC", value.strip())
    if not value or len(value.encode("utf-8")) > 192:
        return None
    for character in value:
        scalar = ord(character)
        if not (0x0C00 <= scalar <= 0x0C7F or scalar in {0x200C, 0x200D}):
            return None
    return value


def source_weight(source: str, score: object) -> float:
    try:
        model_score = float(score)
    except (TypeError, ValueError):
        model_score = 0.0
    return SOURCE_PRIOR.get(source, 1.5) + max(-4.0, min(1.0, model_score))


def ingest(zip_path: Path, member: str,
           database: sqlite3.Connection) -> tuple[int, int, str]:
    if "train" not in Path(member).stem.lower():
        raise ValueError("only an Aksharantar training member may build a lexicon")
    database.executescript("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        PRAGMA temp_store=FILE;
        CREATE TABLE pairs (
            roman TEXT NOT NULL,
            native TEXT NOT NULL,
            weight REAL NOT NULL,
            source_bits INTEGER NOT NULL,
            PRIMARY KEY (roman, native)
        ) WITHOUT ROWID;
    """)
    accepted = rejected = 0
    member_digest = hashlib.sha256()
    with zipfile.ZipFile(zip_path) as archive:
        if member not in archive.namelist():
            raise ValueError(f"zip member not found: {member}")
        with archive.open(member) as handle:
            batch: list[tuple[str, str, float, int]] = []
            for raw_line in handle:
                member_digest.update(raw_line)
                try:
                    row = json.loads(raw_line)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    rejected += 1
                    continue
                roman = normalize_roman(row.get("english word"))
                native = normalize_telugu(row.get("native word"))
                if roman is None or native is None:
                    rejected += 1
                    continue
                source = str(row.get("source", ""))
                batch.append((roman, native, source_weight(source, row.get("score")),
                              SOURCE_BITS.get(source, 0)))
                accepted += 1
                if len(batch) >= 10_000:
                    _insert_batch(database, batch)
                    batch.clear()
            if batch:
                _insert_batch(database, batch)
    database.commit()
    return accepted, rejected, member_digest.hexdigest()


def _insert_batch(database: sqlite3.Connection,
                  batch: list[tuple[str, str, float, int]]) -> None:
    database.executemany("""
        INSERT INTO pairs (roman, native, weight, source_bits) VALUES (?, ?, ?, ?)
        ON CONFLICT (roman, native) DO UPDATE SET
            weight = MAX(weight, excluded.weight),
            source_bits = source_bits | excluded.source_bits
    """, batch)


def ingest_reviewed_core(path: Path,
                         database: sqlite3.Connection) -> tuple[int, str]:
    """Add explicit project-reviewed aliases without consuming held-out data."""
    rows: list[tuple[str, str, float, int]] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        required = {"roman", "native", "weight", "review_status"}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError("reviewed core TSV has an invalid header")
        for line, row in enumerate(reader, start=2):
            if row["review_status"] != "approved":
                raise ValueError(f"reviewed core row {line} is not approved")
            roman = normalize_roman(row["roman"])
            native = normalize_telugu(row["native"])
            try:
                weight = float(row["weight"])
            except (TypeError, ValueError) as error:
                raise ValueError(f"reviewed core row {line} has an invalid weight") from error
            if roman is None or native is None or not 5.0 <= weight <= 12.0:
                raise ValueError(f"reviewed core row {line} is invalid")
            rows.append((roman, native, weight, SOURCE_BITS["ProjectCore"]))
    if not rows:
        raise ValueError("reviewed core TSV is empty")
    _insert_batch(database, rows)
    database.commit()
    return len(rows), sha256(path)


def select_keys(database: sqlite3.Connection, max_keys: int,
                corpus_sentences: list[tuple[list[str], int]] | None = None) -> None:
    database.executescript("""
        CREATE TEMP TABLE key_quality AS
        SELECT roman, MAX(weight) AS quality, COUNT(*) AS variants
        FROM pairs GROUP BY roman;
        CREATE INDEX key_quality_rank ON key_quality(quality DESC, variants DESC, roman);
        CREATE TEMP TABLE corpus_frequency (
            roman TEXT PRIMARY KEY,
            boost REAL NOT NULL
        ) WITHOUT ROWID;
    """)
    if corpus_sentences:
        counts: collections.Counter[str] = collections.Counter()
        for words, weight in corpus_sentences:
            for word in words:
                counts[word] += weight
        database.executemany(
            "INSERT INTO corpus_frequency(roman, boost) VALUES (?, ?)",
            ((word, min(6.0, math.log1p(count) * 1.25))
             for word, count in counts.items()),
        )
    database.execute("CREATE TEMP TABLE selected (roman TEXT PRIMARY KEY) WITHOUT ROWID")
    database.execute("""
        INSERT INTO selected
        SELECT q.roman FROM key_quality q
        LEFT JOIN corpus_frequency c ON c.roman = q.roman
        ORDER BY q.quality + COALESCE(c.boost, 0) DESC,
                 q.variants DESC, q.roman ASC LIMIT ?
    """, (max_keys,))


def _group_roman_ngrams(
    sentences: list[tuple[list[str], int]], key_ids: dict[str, int]
) -> tuple[dict[int, list[tuple[int, int]]], dict[int, list[tuple[int, int]]]]:
    """Count only contiguous in-vocabulary arcs; unknown words break context."""
    unigrams: dict[int, int] = {}
    bigrams: dict[tuple[int, int], int] = {}
    trigrams: dict[tuple[int, int, int], int] = {}
    for words, weight in sentences:
        ids = [key_ids.get(word) for word in words]
        for word_id in ids:
            if word_id is not None:
                unigrams[word_id] = min(
                    0xFFFFFFFF, unigrams.get(word_id, 0) + weight)
        for index in range(len(ids) - 1):
            first, second = ids[index:index + 2]
            if first is not None and second is not None:
                key = (first, second)
                bigrams[key] = min(0xFFFFFFFF, bigrams.get(key, 0) + weight)
        for index in range(len(ids) - 2):
            first, second, third = ids[index:index + 3]
            if first is not None and second is not None and third is not None:
                key = (first, second, third)
                trigrams[key] = min(0xFFFFFFFF, trigrams.get(key, 0) + weight)

    def group_bigram() -> dict[int, list[tuple[int, int]]]:
        # Key IDs stop at 65,533, leaving UInt16.max available as an immutable
        # sentence-start/unknown-context record without changing KBXL-v3.
        grouped: dict[int, list[tuple[int, int]]] = {
            ROMAN_START_CONTEXT: sorted(
                unigrams.items(), key=lambda item: (-item[1], item[0]))
        } if unigrams else {}
        for (previous, word), count in bigrams.items():
            grouped.setdefault(previous, []).append((word, count))
        return {context: sorted(values, key=lambda item: (-item[1], item[0]))
                for context, values in grouped.items()}

    def group_trigram() -> dict[int, list[tuple[int, int]]]:
        grouped: dict[int, list[tuple[int, int]]] = {}
        for (first, second, word), count in trigrams.items():
            grouped.setdefault((first << 16) | second, []).append((word, count))
        return {context: sorted(values, key=lambda item: (-item[1], item[0]))
                for context, values in grouped.items()}

    return group_bigram(), group_trigram()


def _encode_contexts(groups: dict[int, list[tuple[int, int]]],
                     record: struct.Struct) -> tuple[bytearray, bytearray, int]:
    contexts = bytearray()
    continuations = bytearray()
    first = 0
    for context in sorted(groups):
        values = groups[context]
        contexts.extend(record.pack(context, first, len(values)))
        for word_id, count in values:
            continuations.extend(CONTINUATION.pack(word_id, count))
        first += len(values)
    return contexts, continuations, first


def _write_binary(database: sqlite3.Connection, output: Path,
                  max_variants: int,
                  sentences: list[tuple[list[str], int]] | None,
                  bigram_byte_budget: int = DEFAULT_BIGRAM_BYTE_BUDGET,
                  trigram_byte_budget: int = DEFAULT_TRIGRAM_BYTE_BUDGET,
                  max_continuations: int = DEFAULT_MAX_CONTINUATIONS) \
        -> tuple[int, int, dict[str, int]]:
    rows = database.execute("""
        SELECT p.roman, p.native, p.weight, p.source_bits
        FROM pairs p JOIN selected s ON s.roman = p.roman
        ORDER BY p.roman ASC, p.weight DESC, p.native ASC
    """)
    grouped: list[tuple[str, list[tuple[str, float, int]]]] = []
    current_roman: str | None = None
    variants: list[tuple[str, float, int]] = []
    for roman, native, weight, bits in rows:
        if roman != current_roman:
            if current_roman is not None:
                grouped.append((current_roman, variants[:max_variants]))
            current_roman, variants = roman, []
        variants.append((native, float(weight), int(bits)))
    if current_roman is not None:
        grouped.append((current_roman, variants[:max_variants]))

    key_count = len(grouped)
    if key_count > 65_534:
        raise ValueError("Roman Telugu vocabulary must contain at most 65,534 keys")
    variant_count = sum(len(value) for _, value in grouped)
    header_struct = HEADER_WITH_LM if sentences is not None else HEADER
    key_offset = header_struct.size
    variant_offset = key_offset + key_count * KEY_RECORD.size
    blob_offset = variant_offset + variant_count * VARIANT_RECORD.size
    blob = bytearray()
    key_records = bytearray()
    variant_records = bytearray()
    native_offsets: dict[bytes, int] = {}
    first_variant = 0
    for roman, values in grouped:
        encoded_roman = roman.encode("utf-8")
        roman_offset = len(blob)
        blob.extend(encoded_roman)
        key_records.extend(KEY_RECORD.pack(
            roman_offset, len(encoded_roman), len(values), first_variant,
        ))
        for native, weight, source_bits in values:
            encoded_native = native.encode("utf-8")
            native_offset = native_offsets.get(encoded_native)
            if native_offset is None:
                native_offset = len(blob)
                native_offsets[encoded_native] = native_offset
                blob.extend(encoded_native)
            variant_records.extend(VARIANT_RECORD.pack(
                native_offset, len(encoded_native), source_bits, weight,
            ))
        first_variant += len(values)
    lm_stats = {
        "roman_bigram_context_count": 0,
        "roman_bigram_continuation_count": 0,
        "roman_trigram_context_count": 0,
        "roman_trigram_continuation_count": 0,
    }
    suffix = bytearray()
    if sentences is None:
        header = HEADER.pack(MAGIC, VERSION, key_count, variant_count, key_offset,
                             variant_offset, blob_offset, len(blob))
    else:
        key_ids = {roman: index for index, (roman, _) in enumerate(grouped)}
        bigrams, trigrams = _group_roman_ngrams(sentences, key_ids)
        bigrams, bigram_compaction = compact_contexts(
            bigrams,
            context_record_bytes=BIGRAM_CONTEXT.size,
            continuation_record_bytes=CONTINUATION.size,
            byte_budget=bigram_byte_budget,
            max_continuations=max_continuations,
        )
        trigrams, trigram_compaction = compact_contexts(
            trigrams,
            context_record_bytes=TRIGRAM_CONTEXT.size,
            continuation_record_bytes=CONTINUATION.size,
            byte_budget=trigram_byte_budget,
            max_continuations=max_continuations,
        )
        bigram_contexts, bigram_continuations, bigram_count = _encode_contexts(
            bigrams, BIGRAM_CONTEXT)
        trigram_contexts, trigram_continuations, trigram_count = _encode_contexts(
            trigrams, TRIGRAM_CONTEXT)
        bigram_context_offset = blob_offset + len(blob)
        bigram_continuation_offset = bigram_context_offset + len(bigram_contexts)
        trigram_context_offset = bigram_continuation_offset + len(bigram_continuations)
        trigram_continuation_offset = trigram_context_offset + len(trigram_contexts)
        suffix.extend(bigram_contexts)
        suffix.extend(bigram_continuations)
        suffix.extend(trigram_contexts)
        suffix.extend(trigram_continuations)
        header = HEADER_WITH_LM.pack(
            MAGIC, VERSION_WITH_LM, key_count, variant_count, key_offset,
            variant_offset, blob_offset, len(blob),
            bigram_context_offset, len(bigrams),
            bigram_continuation_offset, bigram_count,
            trigram_context_offset, len(trigrams),
            trigram_continuation_offset, trigram_count,
        )
        lm_stats = {
            "roman_bigram_context_count": len(bigrams),
            "roman_bigram_continuation_count": bigram_count,
            "roman_trigram_context_count": len(trigrams),
            "roman_trigram_continuation_count": trigram_count,
            **{f"roman_bigram_{key}": value
               for key, value in bigram_compaction.items()},
            **{f"roman_trigram_{key}": value
               for key, value in trigram_compaction.items()},
        }
    with output.open("wb") as handle:
        handle.write(header)
        handle.write(key_records)
        handle.write(variant_records)
        handle.write(blob)
        handle.write(suffix)
    return key_count, variant_count, lm_stats


def write_binary(database: sqlite3.Connection, output: Path,
                 max_variants: int) -> tuple[int, int]:
    key_count, variant_count, _ = _write_binary(
        database, output, max_variants, sentences=None)
    return key_count, variant_count


def write_binary_with_lm(database: sqlite3.Connection, output: Path,
                         max_variants: int,
                         sentences: list[tuple[list[str], int]], *,
                         bigram_byte_budget: int = DEFAULT_BIGRAM_BYTE_BUDGET,
                         trigram_byte_budget: int = DEFAULT_TRIGRAM_BYTE_BUDGET,
                         max_continuations: int = DEFAULT_MAX_CONTINUATIONS) \
        -> tuple[int, int, dict[str, int]]:
    return _write_binary(
        database, output, max_variants, sentences=sentences,
        bigram_byte_budget=bigram_byte_budget,
        trigram_byte_budget=trigram_byte_budget,
        max_continuations=max_continuations,
    )


def build_pack(args: argparse.Namespace) -> Path:
    if not args.license_ack:
        raise ValueError("pass --license-ack after reviewing Aksharantar CC-BY/CC0 provenance")
    if args.max_keys <= 0 or not 1 <= args.max_variants <= 8:
        raise ValueError("max-keys must be positive and max-variants must be 1...8")
    if args.output_dir.is_symlink():
        raise ValueError("output-dir must not be a symlink")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / "tenglish_lexicon.bin"
    if output.is_symlink():
        raise ValueError("refusing to overwrite a symlinked output artifact")
    with tempfile.TemporaryDirectory(prefix="glyph-tenglish-") as temp:
        database = sqlite3.connect(Path(temp) / "pairs.sqlite3")
        accepted, rejected, member_hash = ingest(args.input_zip, args.member, database)
        reviewed_core = getattr(args, "reviewed_core", None)
        core_rows = 0
        core_hash = None
        if reviewed_core is not None:
            core_rows, core_hash = ingest_reviewed_core(reviewed_core, database)
        select_keys(database, args.max_keys)
        key_count, variant_count = write_binary(database, output, args.max_variants)
        database.close()
    artifact_hash = sha256(output)
    archive_hash = sha256(args.input_zip)
    manifest = {
        "schema_version": 1,
        "identifier": args.identifier,
        "version": args.version,
        "locale": "te_IN",
        "input_modes": ["tenglish"],
        "normalization": "NFC",
        "minimum_ios": "18.0",
        "release_status": "research",
        "benchmark_version": "unvalidated",
        "native_speaker_reviewed": False,
        "artifacts": {
            "layout": None,
            "lexicon": {
                "path": output.name,
                "sha256": artifact_hash,
                "bytes": output.stat().st_size,
                "format": "KBXL-v2-compact-sorted-weighted-lexicon",
            },
            "transliteration_lexicon": {
                "path": output.name,
                "sha256": artifact_hash,
                "bytes": output.stat().st_size,
                "format": "KBXL-v2-compact-sorted-weighted-lexicon",
            },
            "transliteration_fst": None,
            "language_model": None,
            "safety": None,
            "benchmark": None,
        },
        "provenance": [{
            "name": f"AI4Bharat Aksharantar/{args.member}",
            "url": DATASET_URL,
            "license": "CC-BY for manually collected rows; CC0 for mined/existing rows",
            "license_url": LICENSE_URL,
            "sha256": member_hash,
            "split": "train",
            "purpose": "training",
        }] + ([{
            "name": "Project-reviewed core Tenglish aliases",
            "url": "project://tools/language_packs/sources/te-IN/tenglish-core-reviewed.tsv",
            "license": "Project-authored",
            "license_url": "project://THIRD_PARTY_NOTICES.md",
            "sha256": core_hash,
            "split": "train",
            "purpose": "training",
        }] if core_hash else []),
        "build": {
            "accepted_rows": accepted,
            "rejected_rows": rejected,
            "key_count": key_count,
            "variant_count": variant_count,
            "max_keys": args.max_keys,
            "max_variants": args.max_variants,
            "source_archive_sha256": archive_hash,
            "reviewed_core_rows": core_rows,
        },
    }
    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                             encoding="utf-8")
    return manifest_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-zip", type=Path, required=True)
    parser.add_argument("--member", default="tel_train.json")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--identifier", default="te-Latn-Aksharantar-research")
    parser.add_argument("--version", type=int, default=1)
    parser.add_argument("--max-keys", type=int, default=150_000)
    parser.add_argument("--max-variants", type=int, default=4)
    parser.add_argument("--reviewed-core", type=Path)
    parser.add_argument("--license-ack", action="store_true")
    return parser.parse_args()


def main() -> None:
    manifest = build_pack(parse_args())
    print(manifest)


if __name__ == "__main__":
    main()
