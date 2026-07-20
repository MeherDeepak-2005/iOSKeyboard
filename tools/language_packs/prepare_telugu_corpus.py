#!/usr/bin/env python3
"""Stream local Telugu corpus shards into a bounded, reviewable LM input."""

from __future__ import annotations

import argparse
import bz2
import collections
import gzip
import hashlib
import heapq
import json
import os
import re
import unicodedata
from pathlib import Path

from build_telugu_pack import tokenize_roman_telugu, tokenize_telugu

FORMATS = {"auto", "text", "jsonl", "parquet"}
SENTENCE_BOUNDARY = re.compile(r"[\r\n]+|(?<=[.!?\u0964\u0965])\s+")
URL_OR_EMAIL = re.compile(r"(?:https?://|www\.|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,})", re.I)
PHONE = re.compile(r"(?:\+?\d[\s().-]*){10,}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _format(path: Path, requested: str) -> str:
    if requested != "auto":
        return requested
    name = path.name.lower()
    if name.endswith(".parquet"):
        return "parquet"
    if name.endswith((".jsonl", ".jsonl.gz", ".jsonl.bz2")):
        return "jsonl"
    return "text"


def _open_text(path: Path):
    if path.name.lower().endswith(".bz2"):
        return bz2.open(path, "rt", encoding="utf-8", errors="strict")
    if path.name.lower().endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="strict")
    return path.open("r", encoding="utf-8", errors="strict")


def _field(row: object, path: str) -> object:
    value = row
    for component in path.split("."):
        if not isinstance(value, dict):
            return None
        value = value.get(component)
    return value


def documents(path: Path, format_name: str, text_field: str):
    if format_name == "parquet":
        try:
            import pyarrow.parquet as parquet
        except ImportError as error:
            raise RuntimeError("pyarrow is required for Parquet corpus shards") from error
        source = parquet.ParquetFile(path)
        if text_field not in source.schema_arrow.names:
            raise ValueError(f"missing Parquet text field {text_field}: {path}")
        for batch in source.iter_batches(columns=[text_field], batch_size=1024):
            for value in batch.column(0).to_pylist():
                if isinstance(value, str):
                    yield value
        return

    with _open_text(path) as handle:
        if format_name == "text":
            yield from handle
            return
        if format_name != "jsonl":
            raise ValueError(f"unsupported input format: {format_name}")
        for line in handle:
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            value = _field(row, text_field)
            if isinstance(value, str):
                yield value


def _script_ratio(text: str, language: str) -> float:
    relevant = 0
    expected = 0
    for character in text:
        if not character.isalpha():
            continue
        relevant += 1
        scalar = ord(character)
        if language == "telugu":
            expected += int(0x0C00 <= scalar <= 0x0C7F)
        else:
            expected += int(character.isascii())
    return expected / relevant if relevant else 0


def normalize_sentence(text: str, *, language: str, min_tokens: int,
                       max_tokens: int, min_script_ratio: float) -> str | None:
    normalized = unicodedata.normalize("NFC" if language == "telugu" else "NFKC", text)
    if URL_OR_EMAIL.search(normalized) or PHONE.search(normalized):
        return None
    if _script_ratio(normalized, language) < min_script_ratio:
        return None
    tokenizer = tokenize_telugu if language == "telugu" else tokenize_roman_telugu
    words = tokenizer(normalized)
    if not min_tokens <= len(words) <= max_tokens:
        return None
    counts = collections.Counter(words)
    if max(counts.values()) > max(4, int(len(words) * 0.4)):
        return None
    return " ".join(words)


def prepare(args: argparse.Namespace) -> dict:
    if args.language not in {"telugu", "roman_telugu"}:
        raise ValueError("language must be telugu or roman_telugu")
    if args.format not in FORMATS:
        raise ValueError("unsupported format")
    if not 1 <= args.max_sentences <= 500_000:
        raise ValueError("max-sentences must be in 1...500,000")
    if not 1 <= args.min_tokens <= args.max_tokens <= 80:
        raise ValueError("token limits must satisfy 1 <= min <= max <= 80")
    if not 0.5 <= args.min_script_ratio <= 1:
        raise ValueError("min-script-ratio must be in 0.5...1.0")
    if args.output.is_symlink() or args.report.is_symlink():
        raise ValueError("refusing to overwrite a symlink")

    heap: list[tuple[int, str]] = []
    selected: set[str] = set()
    stats = collections.Counter()
    inputs = []
    for path in args.input:
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"input must be a regular non-symlink file: {path}")
        format_name = _format(path, args.format)
        inputs.append({
            "path": str(path),
            "bytes": path.stat().st_size,
            "sha256": sha256(path),
            "format": format_name,
        })
        for document in documents(path, format_name, args.text_field):
            stats["documents"] += 1
            for fragment in SENTENCE_BOUNDARY.split(document):
                stats["fragments"] += 1
                if len(fragment) > args.max_fragment_characters:
                    stats["rejected_too_long"] += 1
                    continue
                sentence = normalize_sentence(
                    fragment,
                    language=args.language,
                    min_tokens=args.min_tokens,
                    max_tokens=args.max_tokens,
                    min_script_ratio=args.min_script_ratio,
                )
                if sentence is None:
                    stats["rejected_filter"] += 1
                    continue
                digest = hashlib.sha256(
                    args.source_id.encode("utf-8") + b"\0" + sentence.encode("utf-8")
                ).digest()
                rank = int.from_bytes(digest[:8], "big")
                item = (-rank, sentence)
                if sentence in selected:
                    stats["duplicates"] += 1
                    continue
                if len(heap) < args.max_sentences:
                    heapq.heappush(heap, item)
                    selected.add(sentence)
                    stats["sample_admissions"] += 1
                elif rank < -heap[0][0]:
                    _, removed = heapq.heapreplace(heap, item)
                    selected.remove(removed)
                    selected.add(sentence)
                    stats["sample_admissions"] += 1

    rows = [sentence for _, sentence in sorted(heap, key=lambda item: -item[0])]
    if not rows:
        raise ValueError("all corpus rows were rejected")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.{os.getpid()}.tmp")
    try:
        opener = bz2.open if args.output.name.lower().endswith(".bz2") else open
        with opener(temporary, "wt", encoding="utf-8") as handle:
            for row in rows:
                handle.write(row + "\n")
        os.replace(temporary, args.output)
    finally:
        temporary.unlink(missing_ok=True)

    report = {
        "schemaVersion": 1,
        "sourceID": args.source_id,
        "language": args.language,
        "inputs": inputs,
        "output": {
            "path": str(args.output),
            "bytes": args.output.stat().st_size,
            "sha256": sha256(args.output),
            "sentences": len(rows),
        },
        "filters": {
            "minTokens": args.min_tokens,
            "maxTokens": args.max_tokens,
            "minScriptRatio": args.min_script_ratio,
            "maxFragmentCharacters": args.max_fragment_characters,
            "rejectsURLsEmailsPhones": True,
            "sampling": "lowest SHA-256 ranks over normalized unique sentences",
        },
        "stats": dict(sorted(stats.items())),
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, action="append", required=True)
    parser.add_argument("--format", choices=sorted(FORMATS), default="auto")
    parser.add_argument("--text-field", default="text")
    parser.add_argument("--language", choices=["telugu", "roman_telugu"], required=True)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--max-sentences", type=int, default=250_000)
    parser.add_argument("--min-tokens", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=40)
    parser.add_argument("--min-script-ratio", type=float, default=0.75)
    parser.add_argument("--max-fragment-characters", type=int, default=2_000)
    return parser.parse_args()


def main() -> None:
    report = prepare(parse_args())
    print(json.dumps(report["output"], ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
