#!/usr/bin/env python3
"""Build a native-review queue from Telugu sentence labels.

This tool never creates runtime policy. It ranks Telugu tokens that are enriched in
positive hate-speech documents, optionally joins exact Aksharantar training records
to produce explicit Roman aliases, and writes every row with `review_status=candidate`.
No source sentence is copied to either output.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import tempfile
import unicodedata
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

HEADER = ["term", "language", "action", "source", "license", "review_status"]
TELUGU_START = 0x0C00
TELUGU_END = 0x0C7F
POSITIVE_LABELS = {"1", "hate", "hatespeech", "true", "yes"}
NEGATIVE_LABELS = {"0", "false", "no", "non-hate", "nonhate"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize_token(value: str) -> str:
    return unicodedata.normalize("NFC", value).strip("'\u2019").casefold()


def is_telugu(value: str) -> bool:
    return any(TELUGU_START <= ord(char) <= TELUGU_END for char in value)


def tokenize(value: str) -> set[str]:
    words: set[str] = set()
    current: list[str] = []

    def flush() -> None:
        token = normalize_token("".join(current))
        current.clear()
        if 2 <= len(token) <= 32 and is_telugu(token):
            words.add(token)

    for char in value:
        category = unicodedata.category(char)
        if category.startswith(("L", "M")) or char in {"'", "\u2019"}:
            current.append(char)
        elif current:
            flush()
    if current:
        flush()
    return words


def read_document_counts(path: Path, text_column: str, label_column: str):
    positive: Counter[str] = Counter()
    negative: Counter[str] = Counter()
    positive_documents = 0
    negative_documents = 0
    with path.open(encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        fields = set(reader.fieldnames or ())
        if text_column not in fields or label_column not in fields:
            raise ValueError(
                f"CSV must contain {text_column!r} and {label_column!r}; got {sorted(fields)}"
            )
        for line_number, row in enumerate(reader, 2):
            label = (row.get(label_column) or "").strip().casefold().replace(" ", "")
            words = tokenize(row.get(text_column) or "")
            if label in POSITIVE_LABELS:
                positive.update(words)
                positive_documents += 1
            elif label in NEGATIVE_LABELS:
                negative.update(words)
                negative_documents += 1
            else:
                raise ValueError(f"unsupported label at CSV row {line_number}: {label!r}")
    if positive_documents == 0 or negative_documents == 0:
        raise ValueError("both positive and negative documents are required")
    return positive, negative, positive_documents, negative_documents


def ranked_terms(
    positive: Counter[str],
    negative: Counter[str],
    positive_documents: int,
    negative_documents: int,
    minimum_positive_documents: int,
    minimum_log_ratio: float,
    limit: int,
):
    rows = []
    for term, positive_count in positive.items():
        if positive_count < minimum_positive_documents:
            continue
        negative_count = negative[term]
        positive_rate = (positive_count + 0.5) / (positive_documents + 1.0)
        negative_rate = (negative_count + 0.5) / (negative_documents + 1.0)
        log_ratio = math.log(positive_rate / negative_rate)
        if log_ratio < minimum_log_ratio:
            continue
        rows.append((term, positive_count, negative_count, log_ratio))
    rows.sort(key=lambda row: (-row[3], -row[1], row[0]))
    return rows[:limit]


def roman_aliases(archive: Path, member: str, native_terms: set[str], limit: int):
    if "train" not in Path(member).name.casefold():
        raise ValueError("only an Aksharantar training member may generate aliases")
    aliases: dict[str, set[str]] = defaultdict(set)
    with zipfile.ZipFile(archive) as source:
        if member not in source.namelist():
            raise ValueError(f"Aksharantar member is missing: {member}")
        with source.open(member) as handle:
            for raw in handle:
                record = json.loads(raw)
                native = normalize_token(str(record.get("native word") or ""))
                if native not in native_terms or len(aliases[native]) >= limit:
                    continue
                roman = normalize_token(str(record.get("english word") or ""))
                if roman and all(char.isascii() and (char.isalpha() or char == "'")
                                 for char in roman):
                    aliases[native].add(roman)
    return aliases


def write_tsv(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="", delete=False,
                                     dir=path.parent, prefix=path.name + ".") as handle:
        writer = csv.DictWriter(handle, fieldnames=HEADER, delimiter="\t",
                                lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
        temporary = Path(handle.name)
    temporary.replace(path)


def build_candidates(
    hate_csv: Path,
    output: Path,
    audit_output: Path,
    *,
    text_column: str = "Sentence",
    label_column: str = "Hate-Speech",
    minimum_positive_documents: int = 2,
    minimum_log_ratio: float = 1.5,
    maximum_terms: int = 300,
    aksharantar: Path | None = None,
    aksharantar_member: str = "tel_train.json",
    aliases_per_term: int = 3,
    expected_hate_sha256: str | None = None,
    expected_aksharantar_sha256: str | None = None,
) -> dict:
    hate_hash = sha256(hate_csv)
    if expected_hate_sha256 and hate_hash != expected_hate_sha256.casefold():
        raise ValueError(f"Telugu hate-speech CSV hash mismatch: {hate_hash}")
    positive, negative, positive_documents, negative_documents = read_document_counts(
        hate_csv, text_column, label_column
    )
    ranked = ranked_terms(positive, negative, positive_documents, negative_documents,
                          minimum_positive_documents, minimum_log_ratio, maximum_terms)
    native_terms = {row[0] for row in ranked}
    aliases: dict[str, set[str]] = {}
    aksharantar_hash = None
    if aksharantar is not None:
        aksharantar_hash = sha256(aksharantar)
        if expected_aksharantar_sha256 \
                and aksharantar_hash != expected_aksharantar_sha256.casefold():
            raise ValueError(f"Aksharantar archive hash mismatch: {aksharantar_hash}")
        aliases = roman_aliases(aksharantar, aksharantar_member, native_terms,
                                aliases_per_term)

    policy_rows: list[dict[str, str]] = []
    for term, _, _, _ in ranked:
        policy_rows.append({
            "term": term,
            "language": "te",
            "action": "suppress_suggest",
            "source": "Telugu-Hatespeech-candidate-miner",
            "license": "CC-BY-4.0",
            "review_status": "candidate",
        })
        for alias in sorted(aliases.get(term, ())):
            policy_rows.append({
                "term": alias,
                "language": "tenglish",
                "action": "suppress_suggest",
                "source": "Telugu-Hatespeech+Aksharantar-explicit-alias",
                "license": "CC-BY-4.0+source-dependent-CC-BY-or-CC0",
                "review_status": "candidate",
            })
    policy_rows.sort(key=lambda row: (row["language"], row["term"]))
    write_tsv(output, policy_rows)

    audit = {
        "schema_version": 1,
        "release_eligible": False,
        "runtime_terms_added": 0,
        "source": {
            "name": "mounikaiiith/Telugu-Hatespeech training split",
            "license": "CC-BY-4.0",
            "sha256": hate_hash,
        },
        "aksharantar": None if aksharantar is None else {
            "member": aksharantar_member,
            "archive_sha256": aksharantar_hash,
            "license": "source-dependent CC-BY/CC0",
        },
        "documents": {"positive": positive_documents, "negative": negative_documents},
        "criteria": {
            "minimum_positive_documents": minimum_positive_documents,
            "minimum_log_ratio": minimum_log_ratio,
            "maximum_native_terms": maximum_terms,
            "aliases_per_native_term": aliases_per_term,
        },
        "candidate_counts": {
            "telugu": len(ranked),
            "tenglish": sum(len(values) for values in aliases.values()),
        },
        "candidates": [{
            "term": term,
            "positive_documents": positive_count,
            "negative_documents": negative_count,
            "log_rate_ratio": round(log_ratio, 6),
            "roman_aliases": sorted(aliases.get(term, ())),
        } for term, positive_count, negative_count, log_ratio in ranked],
        "policy": "Sentence labels produce a review queue only. Native-speaker approval is required per exact term and alias before runtime inclusion.",
    }
    audit_output.write_text(json.dumps(audit, ensure_ascii=False, indent=2,
                                      sort_keys=True) + "\n", encoding="utf-8")
    return audit


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hate-csv", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--audit-output", type=Path, required=True)
    parser.add_argument("--text-column", default="Sentence")
    parser.add_argument("--label-column", default="Hate-Speech")
    parser.add_argument("--minimum-positive-documents", type=int, default=2)
    parser.add_argument("--minimum-log-ratio", type=float, default=1.5)
    parser.add_argument("--maximum-terms", type=int, default=300)
    parser.add_argument("--aksharantar", type=Path)
    parser.add_argument("--aksharantar-member", default="tel_train.json")
    parser.add_argument("--aliases-per-term", type=int, default=3)
    parser.add_argument("--expected-hate-sha256")
    parser.add_argument("--expected-aksharantar-sha256")
    args = parser.parse_args()
    audit = build_candidates(
        args.hate_csv, args.output, args.audit_output,
        text_column=args.text_column, label_column=args.label_column,
        minimum_positive_documents=args.minimum_positive_documents,
        minimum_log_ratio=args.minimum_log_ratio, maximum_terms=args.maximum_terms,
        aksharantar=args.aksharantar, aksharantar_member=args.aksharantar_member,
        aliases_per_term=args.aliases_per_term,
        expected_hate_sha256=args.expected_hate_sha256,
        expected_aksharantar_sha256=args.expected_aksharantar_sha256,
    )
    counts = audit["candidate_counts"]
    print(f"wrote review-only candidates: {counts['telugu']} Telugu, "
          f"{counts['tenglish']} Tenglish; runtime terms added: 0")


if __name__ == "__main__":
    main()
