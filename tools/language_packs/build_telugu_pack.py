#!/usr/bin/env python3
"""Compile the Telugu runtime pack from reviewable layout and public datasets.

The extension consumes only deterministic binary artifacts. Telugu glyph placement,
composition classes, accessibility names, native vocabulary, transliteration pairs,
and n-grams all live outside Swift.
"""

from __future__ import annotations

import argparse
import bz2
import collections
import hashlib
import heapq
import json
import math
import plistlib
import re
import sqlite3
import struct
import tempfile
import unicodedata
from pathlib import Path
from urllib.parse import urlparse

import build_tenglish_lexicon as tenglish
from ngram_compaction import compact_contexts

MAGIC = b"KBTD"
VERSION = 1
NONE_WORD = 0xFFFF

# magic + 18 UInt32 fields (see write_telugu_data).
HEADER = struct.Struct("<4s18I")
WORD_RECORD = struct.Struct("<IHH")
NODE_RECORD = struct.Struct("<IHHH")
EDGE_RECORD = struct.Struct("<HI")
BIGRAM_CONTEXT = struct.Struct("<HII")
TRIGRAM_CONTEXT = struct.Struct("<III")
CONTINUATION = struct.Struct("<HI")
DEFAULT_NATIVE_BIGRAM_BYTE_BUDGET = 112 * 1024
DEFAULT_NATIVE_TRIGRAM_BYTE_BUDGET = 112 * 1024
DEFAULT_NATIVE_MAX_CONTINUATIONS = 24

TATOEBA_URL = "https://downloads.tatoeba.org/exports/per_language/tel/"
TATOEBA_LICENSE = "https://creativecommons.org/licenses/by/2.0/fr/"
CORPUS_MANIFEST_SCHEMA = 1
ROMAN_TOKEN = re.compile(r"[a-z]+(?:'[a-z]+)?")
WeightedSentence = tuple[list[str], int]


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize_telugu_word(value: str) -> str | None:
    value = unicodedata.normalize("NFC", value.strip())
    if not value or len(value.encode("utf-8")) > 192:
        return None
    for character in value:
        scalar = ord(character)
        if not (0x0C00 <= scalar <= 0x0C7F or scalar in {0x200C, 0x200D}):
            return None
    return value


def tokenize_telugu(text: str) -> list[str]:
    words: list[str] = []
    current: list[str] = []
    for character in unicodedata.normalize("NFC", text):
        scalar = ord(character)
        if 0x0C00 <= scalar <= 0x0C7F or scalar in {0x200C, 0x200D}:
            current.append(character)
        elif current:
            value = normalize_telugu_word("".join(current))
            if value:
                words.append(value)
            current.clear()
    if current:
        value = normalize_telugu_word("".join(current))
        if value:
            words.append(value)
    return words


def read_tatoeba(path: Path) -> tuple[list[list[str]], list[str]]:
    sentences: list[list[str]] = []
    contributors: set[str] = set()
    with bz2.open(path, "rt", encoding="utf-8", errors="strict") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 3 or fields[1] != "tel":
                continue
            words = tokenize_telugu(fields[2])
            if words:
                sentences.append(words)
                if len(fields) >= 4 and fields[3].strip():
                    contributors.add(fields[3].strip())
    return sentences, sorted(contributors, key=str.casefold)


def tokenize_roman_telugu(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).lower()
    normalized = normalized.replace("’", "'").replace("‘", "'").replace("`", "'")
    return [token for match in ROMAN_TOKEN.finditer(normalized)
            if (token := tenglish.normalize_roman(match.group(0))) is not None]


def _open_text(path: Path):
    if path.suffix == ".bz2":
        return bz2.open(path, "rt", encoding="utf-8", errors="strict")
    return path.open("r", encoding="utf-8", errors="strict")


def _bounded_sample(rows, source_id: str, max_sentences: int) \
        -> tuple[list[list[str]], dict[str, int]]:
    """Keep a deterministic hash sample so file ordering cannot bias starters."""
    heap: list[tuple[int, tuple[str, ...]]] = []
    selected: set[tuple[str, ...]] = set()
    scanned = valid = admitted = rejected = duplicates = 0
    for words in rows:
        scanned += 1
        if not words:
            rejected += 1
            continue
        valid += 1
        key = tuple(words)
        if key in selected:
            duplicates += 1
            continue
        digest = hashlib.sha256(
            source_id.encode("utf-8") + b"\0" + "\0".join(key).encode("utf-8")
        ).digest()
        rank = int.from_bytes(digest[:8], "big")
        item = (-rank, key)
        if len(heap) < max_sentences:
            heapq.heappush(heap, item)
            selected.add(key)
            admitted += 1
        elif rank < -heap[0][0]:
            _, removed = heapq.heapreplace(heap, item)
            selected.remove(removed)
            selected.add(key)
            admitted += 1
    ordered = [list(words) for _, words in sorted(heap, key=lambda item: -item[0])]
    return ordered, {
        "scanned": scanned,
        "valid": valid,
        "sample_admissions": admitted,
        "selected": len(ordered),
        "rejected": rejected,
        "duplicates": duplicates,
    }


def _corpus_rows(source: dict, path: Path):
    language = source["language"]
    tokenizer = tokenize_telugu if language == "telugu" else tokenize_roman_telugu
    format_name = source["format"]
    with _open_text(path) as handle:
        if format_name == "text":
            for line in handle:
                yield tokenizer(line)
        elif format_name == "jsonl":
            field = source.get("textField", "text")
            for line in handle:
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    yield []
                    continue
                value = row.get(field) if isinstance(row, dict) else None
                yield tokenizer(value) if isinstance(value, str) else []
        elif format_name == "tatoeba_tsv":
            for line in handle:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 3 or fields[1] != "tel":
                    yield []
                    continue
                yield tokenizer(fields[2])
        else:
            raise ValueError(f"unsupported corpus format: {format_name}")


def _validate_corpus_source(source: object, manifest_path: Path) -> tuple[dict, Path]:
    if not isinstance(source, dict):
        raise ValueError("corpus sources must be objects")
    required = {
        "id", "name", "path", "url", "license", "licenseURL", "sha256",
        "sourceRevision", "attribution", "split", "purpose", "language",
        "domain", "format", "countWeight", "maxSentences", "researchOnly",
        "releaseEligible",
    }
    optional = {"textField"}
    if set(source) - required - optional or not required.issubset(source):
        raise ValueError(f"corpus source {source.get('id', '<unknown>')} has invalid fields")
    for field in {
        "id", "name", "path", "url", "license", "licenseURL", "sha256",
        "sourceRevision", "attribution",
    }:
        if not isinstance(source[field], str) or not source[field].strip():
            raise ValueError(f"corpus source field {field} must be a non-empty string")
    if not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
        raise ValueError("corpus source sha256 must be lowercase hexadecimal")
    for field in ("url", "licenseURL"):
        if urlparse(source[field]).scheme not in {"https", "project"}:
            raise ValueError(f"corpus source {field} must use https or project")
    if source["split"] != "train" or source["purpose"] != "training":
        raise ValueError("only training corpus sources may build runtime language data")
    if source["language"] not in {"telugu", "roman_telugu"}:
        raise ValueError("corpus language must be telugu or roman_telugu")
    if source["domain"] not in {"conversational", "formal", "news", "synthetic", "mixed"}:
        raise ValueError("unsupported corpus domain")
    if source["format"] not in {"text", "jsonl", "tatoeba_tsv"}:
        raise ValueError("unsupported corpus format")
    if source["format"] == "tatoeba_tsv" and source["language"] != "telugu":
        raise ValueError("Tatoeba TSV input must use the native Telugu tokenizer")
    if not isinstance(source["countWeight"], int) or not 1 <= source["countWeight"] <= 100:
        raise ValueError("countWeight must be an integer in 1...100")
    if not isinstance(source["maxSentences"], int) \
            or not 1 <= source["maxSentences"] <= 500_000:
        raise ValueError("maxSentences must be in 1...500,000")
    if not isinstance(source["researchOnly"], bool) \
            or not isinstance(source["releaseEligible"], bool):
        raise ValueError("corpus release flags must be booleans")
    if source["researchOnly"] and source["releaseEligible"]:
        raise ValueError("a research-only source cannot be release-eligible")
    relative = Path(source["path"])
    if relative.is_absolute():
        raise ValueError("corpus paths must be relative to the manifest")
    unresolved = manifest_path.parent / relative
    if unresolved.is_symlink():
        raise ValueError(f"corpus source is symlinked: {unresolved}")
    path = unresolved.resolve()
    if not path.is_file():
        raise ValueError(f"corpus source is missing: {path}")
    if file_sha256(path) != source["sha256"]:
        raise ValueError(f"corpus source hash mismatch: {source['id']}")
    return source, path


def read_corpus_manifest(path: Path) \
        -> tuple[list[WeightedSentence], list[WeightedSentence], list[dict], dict]:
    if path.is_symlink() or not path.is_file():
        raise ValueError("corpus manifest must be a regular non-symlink file")
    document = json.loads(path.read_text(encoding="utf-8"))
    if set(document) != {"schemaVersion", "sources"} \
            or document.get("schemaVersion") != CORPUS_MANIFEST_SCHEMA \
            or not isinstance(document.get("sources"), list) \
            or not document["sources"]:
        raise ValueError("invalid corpus manifest")
    native: list[WeightedSentence] = []
    roman: list[WeightedSentence] = []
    provenance: list[dict] = []
    source_stats: dict[str, dict] = {}
    seen_ids: set[str] = set()
    for value in document["sources"]:
        source, source_path = _validate_corpus_source(value, path)
        source_id = source["id"]
        if not isinstance(source_id, str) or not source_id \
                or source_id in seen_ids:
            raise ValueError("corpus source IDs must be unique non-empty strings")
        seen_ids.add(source_id)
        sampled, stats = _bounded_sample(
            _corpus_rows(source, source_path), source_id, source["maxSentences"])
        if source["format"] == "tatoeba_tsv":
            _, contributors = read_tatoeba(source_path)
            stats["contributors"] = contributors
        weighted = [(words, source["countWeight"]) for words in sampled]
        (native if source["language"] == "telugu" else roman).extend(weighted)
        source_stats[source_id] = {
            **stats,
            "language": source["language"],
            "domain": source["domain"],
            "count_weight": source["countWeight"],
            "max_sentences": source["maxSentences"],
        }
        provenance.append({
            "name": source["name"],
            "url": source["url"],
            "license": source["license"],
            "license_url": source["licenseURL"],
            "sha256": source["sha256"],
            "split": source["split"],
            "purpose": source["purpose"],
            "source_revision": source["sourceRevision"],
            "attribution": source["attribution"],
            "research_only": source["researchOnly"],
            "release_eligible": source["releaseEligible"],
        })
    return native, roman, provenance, source_stats


def compile_layout(source: Path, output: Path) -> dict:
    document = json.loads(source.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1:
        raise ValueError("unsupported layout schema")
    if document.get("normalization") != "NFC":
        raise ValueError("layout normalization must be NFC")
    pages = document.get("pages")
    page_ids = {page.get("id") for page in pages} if isinstance(pages, list) else set()
    if not isinstance(pages, list) or not {"alphabetic", "numbers"} <= page_ids \
            or not page_ids <= {"alphabetic", "shift", "numbers"}:
        raise ValueError("layout must contain alphabetic and numbers pages")
    composition = document.get("composition")
    if not isinstance(composition, dict):
        raise ValueError("layout is missing composition metadata")
    classes = {
        "consonant": set(composition.get("consonants", [])),
        "dependentVowel": set(composition.get("dependentVowelSigns", [])),
        "mark": set(composition.get("marks", [])),
        "virama": {composition.get("virama")},
    }
    def validate_key(key: dict) -> None:
        if key.get("kind") not in {
            "text", "vowel", "consonant", "dependentVowel", "mark", "virama"
        }:
            raise ValueError(f"invalid key kind: {key.get('kind')}")
        for field in ("label", "accessibilityLabel", "text"):
            if not isinstance(key.get(field), str) or not key[field]:
                raise ValueError(f"layout key is missing {field}")
        kind = key["kind"]
        if kind == "vowel" and key.get("dependentText") is not None:
            dependent = unicodedata.normalize("NFC", key["dependentText"])
            if not dependent or any(not (0x0C00 <= ord(char) <= 0x0C7F)
                                    for char in dependent):
                raise ValueError(f"invalid dependent vowel for {key['label']}")
        if kind in classes:
            scalars = list(map(ord, unicodedata.normalize("NFC", key["text"])))
            if len(scalars) != 1 or scalars[0] not in classes[kind]:
                raise ValueError(
                    f"layout {kind} key {key['label']} is absent from composition metadata"
                )

    alphabetic_rows = next(page["rows"] for page in pages
                           if page.get("id") == "alphabetic")
    if not 3 <= len(alphabetic_rows) <= 6:
        raise ValueError("alphabetic layout must contain 3...6 glyph rows")
    shift_page = next((page for page in pages if page.get("id") == "shift"), None)
    if shift_page is not None and len(shift_page.get("rows", [])) != len(alphabetic_rows):
        raise ValueError("shift and alphabetic pages must have the same row count")

    for page in pages:
        rows = page.get("rows")
        if not isinstance(rows, list) or not rows:
            raise ValueError(f"layout page {page.get('id')} has no rows")
        for row in rows:
            if not isinstance(row, list) or not row:
                raise ValueError("layout rows must be non-empty")
            for key in row:
                validate_key(key)
    bottom_keys = document.get("bottomKeys", [])
    if not isinstance(bottom_keys, list) or len(bottom_keys) > 2:
        raise ValueError("bottomKeys must contain at most two controls")
    for key in bottom_keys:
        validate_key(key)
    payload = plistlib.dumps(document, fmt=plistlib.FMT_BINARY, sort_keys=True)
    output.write_bytes(payload)
    return document


def native_scores(database: sqlite3.Connection) -> dict[str, float]:
    scores: dict[str, float] = {}
    rows = database.execute("""
        SELECT native, COUNT(*) AS variants, SUM(MAX(weight, 0.25)) AS score
        FROM pairs GROUP BY native
    """)
    for native, variants, score in rows:
        value = normalize_telugu_word(native)
        if value:
            scores[value] = float(score) + math.log1p(int(variants))
    return scores


def romanize_sentences(database: sqlite3.Connection,
                       sentences: list[WeightedSentence]) -> list[WeightedSentence]:
    """Project native sentences through the highest-weight selected attested form."""
    rows = database.execute("""
        SELECT p.native, p.roman, p.weight
        FROM pairs p JOIN selected s ON s.roman = p.roman
        ORDER BY p.native ASC, p.weight DESC, p.roman ASC
    """)
    best: dict[str, str] = {}
    for native, roman, _ in rows:
        best.setdefault(native, roman)
    return [([best.get(word, "") for word in words], weight)
            for words, weight in sentences]


def select_vocabulary(scores: dict[str, float], sentences: list[WeightedSentence],
                      max_words: int) -> tuple[list[str], dict[str, float]]:
    sentence_counts: collections.Counter[str] = collections.Counter()
    for sentence, weight in sentences:
        for word in sentence:
            sentence_counts[word] += weight
    for word, count in sentence_counts.items():
        scores[word] = scores.get(word, 0.0) + 50.0 * count
    ranked = sorted(scores, key=lambda word: (-scores[word], word))
    words = ranked[:max_words]
    return words, scores


def build_trie(words: list[str]) -> tuple[list[dict[int, int]], list[int], list[int]]:
    children: list[dict[int, int]] = [{}]
    terminal: list[int] = [NONE_WORD]
    for word_id, word in enumerate(words):
        node = 0
        for scalar in map(ord, word):
            if scalar > 0xFFFF:
                raise ValueError(f"unsupported scalar in Telugu vocabulary: U+{scalar:04X}")
            child = children[node].get(scalar)
            if child is None:
                child = len(children)
                children[node][scalar] = child
                children.append({})
                terminal.append(NONE_WORD)
            node = child
        terminal[node] = word_id

    top: list[int] = [NONE_WORD for _ in children]
    for node in range(len(children) - 1, -1, -1):
        candidates: list[int] = []
        if terminal[node] != NONE_WORD:
            candidates.append(terminal[node])
        for child in children[node].values():
            if top[child] != NONE_WORD:
                candidates.append(top[child])
        top[node] = min(candidates, default=NONE_WORD)
    return children, terminal, top


def group_ngrams(sentences: list[WeightedSentence], word_ids: dict[str, int]):
    bigrams: collections.Counter[tuple[int, int]] = collections.Counter()
    trigrams: collections.Counter[tuple[int, int, int]] = collections.Counter()
    for sentence, weight in sentences:
        ids = [word_ids.get(word) for word in sentence]
        for index in range(len(ids) - 1):
            first, second = ids[index:index + 2]
            if first is not None and second is not None:
                bigrams[first, second] += weight
        for index in range(len(ids) - 2):
            first, second, third = ids[index:index + 3]
            if first is not None and second is not None and third is not None:
                trigrams[first, second, third] += weight

    def grouped_bigram():
        grouped: dict[int, list[tuple[int, int]]] = collections.defaultdict(list)
        for (previous, word), count in bigrams.items():
            grouped[previous].append((word, count))
        return {
            context: sorted(values, key=lambda item: (-item[1], item[0]))
            for context, values in grouped.items()
        }

    def grouped_trigram():
        grouped: dict[int, list[tuple[int, int]]] = collections.defaultdict(list)
        for (first, second, word), count in trigrams.items():
            grouped[(first << 16) | second].append((word, count))
        return {
            context: sorted(values, key=lambda item: (-item[1], item[0]))
            for context, values in grouped.items()
        }

    return grouped_bigram(), grouped_trigram()


def write_telugu_data(output: Path, words: list[str], scores: dict[str, float],
                      sentences: list[WeightedSentence], *,
                      bigram_byte_budget: int = DEFAULT_NATIVE_BIGRAM_BYTE_BUDGET,
                      trigram_byte_budget: int = DEFAULT_NATIVE_TRIGRAM_BYTE_BUDGET,
                      max_continuations: int = DEFAULT_NATIVE_MAX_CONTINUATIONS) \
        -> dict[str, int]:
    if not 1 <= len(words) <= 65_534:
        raise ValueError("Telugu vocabulary must contain 1...65,534 words")
    word_ids = {word: index for index, word in enumerate(words)}
    children, terminals, tops = build_trie(words)
    bigrams, trigrams = group_ngrams(sentences, word_ids)
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

    blob = bytearray()
    word_records = bytearray()
    for word in words:
        encoded = word.encode("utf-8")
        offset = len(blob)
        blob.extend(encoded)
        quantized = min(0xFFFF, max(0, round(math.log1p(scores[word]) * 4096)))
        word_records.extend(WORD_RECORD.pack(offset, len(encoded), quantized))

    edges = bytearray()
    node_records = bytearray()
    edge_index = 0
    for node, values in enumerate(children):
        ordered = sorted(values.items())
        node_records.extend(NODE_RECORD.pack(
            edge_index, len(ordered), terminals[node], tops[node],
        ))
        for scalar, child in ordered:
            edges.extend(EDGE_RECORD.pack(scalar, child))
        edge_index += len(ordered)

    def encode_contexts(groups: dict[int, list[tuple[int, int]]], record: struct.Struct):
        contexts = bytearray()
        continuations = bytearray()
        first = 0
        for context in sorted(groups):
            values = groups[context]
            contexts.extend(record.pack(context, first, len(values)))
            for word_id, count in values:
                continuations.extend(CONTINUATION.pack(word_id, min(count, 0xFFFFFFFF)))
            first += len(values)
        return contexts, continuations, first

    bigram_contexts, bigram_continuations, bigram_count = encode_contexts(
        bigrams, BIGRAM_CONTEXT)
    trigram_contexts, trigram_continuations, trigram_count = encode_contexts(
        trigrams, TRIGRAM_CONTEXT)

    sections = [
        word_records, node_records, edges, bigram_contexts, bigram_continuations,
        trigram_contexts, trigram_continuations, blob,
    ]
    offsets: list[int] = []
    cursor = HEADER.size
    for section in sections:
        offsets.append(cursor)
        cursor += len(section)
    header = HEADER.pack(
        MAGIC, VERSION, len(words), len(children), edge_index,
        len(bigrams), bigram_count, len(trigrams), trigram_count,
        offsets[0], offsets[1], offsets[2], offsets[3], offsets[4],
        offsets[5], offsets[6], offsets[7], len(blob), 0,
    )
    with output.open("wb") as handle:
        handle.write(header)
        for section in sections:
            handle.write(section)
    return {
        "word_count": len(words),
        "trie_node_count": len(children),
        "trie_edge_count": edge_index,
        "bigram_context_count": len(bigrams),
        "bigram_continuation_count": bigram_count,
        "trigram_context_count": len(trigrams),
        "trigram_continuation_count": trigram_count,
        **{f"native_bigram_{key}": value
           for key, value in bigram_compaction.items()},
        **{f"native_trigram_{key}": value
           for key, value in trigram_compaction.items()},
    }


def artifact(path: Path, format_name: str) -> dict:
    return {
        "path": path.name,
        "sha256": file_sha256(path),
        "bytes": path.stat().st_size,
        "format": format_name,
    }


def build(args: argparse.Namespace) -> Path:
    if not args.license_ack:
        raise ValueError("pass --license-ack after reviewing every language-data source")
    if not 1 <= args.max_words <= 65_534:
        raise ValueError("max-words must be 1...65,534")
    for field, fallback in {
        "native_bigram_byte_budget": DEFAULT_NATIVE_BIGRAM_BYTE_BUDGET,
        "native_trigram_byte_budget": DEFAULT_NATIVE_TRIGRAM_BYTE_BUDGET,
        "roman_bigram_byte_budget": tenglish.DEFAULT_BIGRAM_BYTE_BUDGET,
        "roman_trigram_byte_budget": tenglish.DEFAULT_TRIGRAM_BYTE_BUDGET,
    }.items():
        if getattr(args, field, fallback) < 0:
            raise ValueError(f"{field.replace('_', '-')} must be non-negative")
    for field, fallback in {
        "native_max_continuations": DEFAULT_NATIVE_MAX_CONTINUATIONS,
        "roman_max_continuations": tenglish.DEFAULT_MAX_CONTINUATIONS,
    }.items():
        if getattr(args, field, fallback) <= 0:
            raise ValueError(f"{field.replace('_', '-')} must be positive")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    layout_output = args.output_dir / "telugu_layout.kbpack"
    data_output = args.output_dir / "telugu_langdata.bin"
    tenglish_output = args.output_dir / "tenglish_lexicon.bin"
    manifest_output = args.output_dir / "telugu_pack_manifest.json"
    for path in (layout_output, data_output, tenglish_output, manifest_output):
        if path.is_symlink():
            raise ValueError(f"refusing to overwrite symlink: {path}")

    layout = compile_layout(args.layout, layout_output)
    corpus_manifest = getattr(args, "corpus_manifest", None)
    legacy_tatoeba = getattr(args, "tatoeba", None)
    if corpus_manifest is not None:
        native_sentences, roman_sentences, corpus_provenance, corpus_stats = \
            read_corpus_manifest(corpus_manifest)
        tatoeba_contributors = sorted({
            contributor
            for stats in corpus_stats.values()
            for contributor in stats.get("contributors", [])
        }, key=str.casefold)
        corpus_manifest_hash = file_sha256(corpus_manifest)
    elif legacy_tatoeba is not None:
        legacy_sentences, tatoeba_contributors = read_tatoeba(legacy_tatoeba)
        native_sentences = [(sentence, 1) for sentence in legacy_sentences]
        roman_sentences = []
        corpus_manifest_hash = None
        corpus_stats = {
            "tatoeba_telugu": {
                "scanned": len(legacy_sentences),
                "selected": len(legacy_sentences),
                "language": "telugu",
                "domain": "mixed",
                "count_weight": 1,
                "max_sentences": len(legacy_sentences),
                "contributors": tatoeba_contributors,
            }
        }
        corpus_provenance = [{
            "name": "Tatoeba Telugu detailed sentences",
            "url": TATOEBA_URL,
            "license": "CC BY 2.0 FR",
            "license_url": TATOEBA_LICENSE,
            "sha256": file_sha256(legacy_tatoeba),
            "split": "train",
            "purpose": "training",
            "source_revision": file_sha256(legacy_tatoeba),
            "attribution": "Tatoeba contributors listed in build metadata",
            "research_only": False,
            "release_eligible": True,
        }]
    else:
        raise ValueError("pass --corpus-manifest (preferred) or --tatoeba")
    if not native_sentences:
        raise ValueError("the corpus manifest contains no native Telugu sentences")
    with tempfile.TemporaryDirectory(prefix="glyph-telugu-") as temporary:
        database = sqlite3.connect(Path(temporary) / "pairs.sqlite3")
        accepted, rejected, member_hash = tenglish.ingest(
            args.aksharantar, args.member, database)
        reviewed_core = getattr(args, "reviewed_core", None)
        core_rows = 0
        core_hash = None
        if reviewed_core is not None:
            core_rows, core_hash = tenglish.ingest_reviewed_core(
                reviewed_core, database)
        scores = native_scores(database)
        words, scores = select_vocabulary(scores, native_sentences, args.max_words)
        data_stats = write_telugu_data(
            data_output, words, scores, native_sentences,
            bigram_byte_budget=getattr(
                args, "native_bigram_byte_budget", DEFAULT_NATIVE_BIGRAM_BYTE_BUDGET),
            trigram_byte_budget=getattr(
                args, "native_trigram_byte_budget", DEFAULT_NATIVE_TRIGRAM_BYTE_BUDGET),
            max_continuations=getattr(
                args, "native_max_continuations", DEFAULT_NATIVE_MAX_CONTINUATIONS),
        )
        # Direct Roman Telugu sentences promote attested Aksharantar spellings into
        # the bounded runtime key set. Synthetic projection is generated afterward
        # and therefore cannot circularly decide which spellings are available.
        tenglish.select_keys(database, args.max_roman_keys, roman_sentences)
        synthetic_roman = romanize_sentences(database, native_sentences)
        all_roman_sentences = roman_sentences + synthetic_roman
        roman_keys, roman_variants, roman_lm_stats = tenglish.write_binary_with_lm(
            database, tenglish_output, args.max_variants, all_roman_sentences,
            bigram_byte_budget=getattr(
                args, "roman_bigram_byte_budget", tenglish.DEFAULT_BIGRAM_BYTE_BUDGET),
            trigram_byte_budget=getattr(
                args, "roman_trigram_byte_budget", tenglish.DEFAULT_TRIGRAM_BYTE_BUDGET),
            max_continuations=getattr(
                args, "roman_max_continuations", tenglish.DEFAULT_MAX_CONTINUATIONS),
        )
        database.close()

    manifest = {
        "schema_version": 2,
        "identifier": layout["identifier"],
        "version": layout["version"],
        "locale": layout["locale"],
        "input_modes": ["tenglish_to_telugu", "roman_telugu", "telugu"],
        "normalization": "NFC",
        "minimum_ios": "18.0",
        "release_status": "research",
        "benchmark_version": "telugu-beta-unvalidated-v2",
        "benchmark_hash": None,
        "native_speaker_reviewed": bool(layout["nativeSpeakerReviewed"]),
        "artifacts": {
            "layout": artifact(layout_output, "binary-plist Telugu-layout-v1"),
            "lexicon": artifact(data_output, "KBTD-v1 compact scalar trie"),
            "transliteration_lexicon": artifact(
                tenglish_output, "KBXL-v3 weighted lexicon + Roman bi-trigram"),
            "transliteration_fst": None,
            "language_model": artifact(data_output, "KBTD-v1 compact bi-trigram"),
            "safety": None,
            "benchmark": None,
        },
        "provenance": [
            {
                "name": "Project-authored Apple-mobile Telugu layout source",
                "url": layout["source"]["url"],
                "license": "Reference implementation data; screenshots are not redistributed",
                "license_url": layout["source"]["cldrURL"],
                "sha256": file_sha256(args.layout),
                "split": "none",
                "purpose": "layout",
                "source_revision": f"layout-v{layout['version']}",
                "attribution": "Project-authored geometry; Unicode character coverage",
                "research_only": False,
                "release_eligible": True,
            },
            {
                "name": f"AI4Bharat Aksharantar/{args.member}",
                "url": tenglish.DATASET_URL,
                "license": "CC-BY for manually collected rows; CC0 for mined/existing rows",
                "license_url": tenglish.LICENSE_URL,
                "sha256": member_hash,
                "split": "train",
                "purpose": "training",
                "source_revision": args.member,
                "attribution": "AI4Bharat Aksharantar contributors",
                "research_only": False,
                "release_eligible": True,
            },
            *([{
                "name": "Project-reviewed core Tenglish aliases",
                "url": "project://tools/language_packs/sources/te-IN/tenglish-core-reviewed.tsv",
                "license": "Project-authored",
                "license_url": "project://THIRD_PARTY_NOTICES.md",
                "sha256": core_hash,
                "split": "train",
                "purpose": "training",
                "source_revision": core_hash,
                "attribution": "Glyph project reviewed aliases",
                "research_only": False,
                "release_eligible": True,
            }] if core_hash else []),
            *corpus_provenance,
        ],
        "build": {
            **data_stats,
            **roman_lm_stats,
            "native_corpus_sentence_count": len(native_sentences),
            "direct_roman_corpus_sentence_count": len(roman_sentences),
            "synthetic_roman_sentence_count": len(synthetic_roman),
            "tatoeba_sentence_count": sum(
                stats["selected"] for identifier, stats in corpus_stats.items()
                if "tatoeba" in identifier.casefold()),
            "tatoeba_contributors": tatoeba_contributors,
            "corpus_manifest_sha256": corpus_manifest_hash,
            "corpus_sources": corpus_stats,
            "aksharantar_accepted_rows": accepted,
            "aksharantar_rejected_rows": rejected,
            "reviewed_core_rows": core_rows,
            "roman_key_count": roman_keys,
            "roman_variant_count": roman_variants,
            "max_words": args.max_words,
            "max_roman_keys": args.max_roman_keys,
            "max_variants": args.max_variants,
            "aksharantar_archive_sha256": file_sha256(args.aksharantar),
        },
    }
    manifest_output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest_output


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--layout", type=Path, required=True)
    parser.add_argument("--aksharantar", type=Path, required=True)
    parser.add_argument("--member", default="tel_train.json")
    corpus = parser.add_mutually_exclusive_group(required=True)
    corpus.add_argument("--corpus-manifest", type=Path)
    corpus.add_argument("--tatoeba", type=Path,
                        help="legacy single-source input; use --corpus-manifest")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--max-words", type=int, default=40_000)
    parser.add_argument("--max-roman-keys", type=int, default=40_000)
    parser.add_argument("--max-variants", type=int, default=3)
    parser.add_argument("--native-bigram-byte-budget", type=int,
                        default=DEFAULT_NATIVE_BIGRAM_BYTE_BUDGET)
    parser.add_argument("--native-trigram-byte-budget", type=int,
                        default=DEFAULT_NATIVE_TRIGRAM_BYTE_BUDGET)
    parser.add_argument("--native-max-continuations", type=int,
                        default=DEFAULT_NATIVE_MAX_CONTINUATIONS)
    parser.add_argument("--roman-bigram-byte-budget", type=int,
                        default=tenglish.DEFAULT_BIGRAM_BYTE_BUDGET)
    parser.add_argument("--roman-trigram-byte-budget", type=int,
                        default=tenglish.DEFAULT_TRIGRAM_BYTE_BUDGET)
    parser.add_argument("--roman-max-continuations", type=int,
                        default=tenglish.DEFAULT_MAX_CONTINUATIONS)
    parser.add_argument("--reviewed-core", type=Path)
    parser.add_argument("--license-ack", action="store_true")
    return parser.parse_args()


def main() -> None:
    print(build(parse_args()))


if __name__ == "__main__":
    main()
