#!/usr/bin/env python3
"""Convert a reviewed KBGUARD1 artifact into the tracked policy TSV schema."""

from __future__ import annotations

import argparse
import hashlib
import struct
from pathlib import Path

HEADER = "term\tlanguage\taction\tsource\tlicense\treview_status\n"
LANGUAGES = {1: "en", 2: "te", 3: "tenglish"}
ACTIONS = {0: "allow", 1: "demote", 2: "suppress_suggest", 3: "suppress_always"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_rows(path: Path) -> list[tuple[str, str, str]]:
    data = path.read_bytes()
    if len(data) < 24 or data[:8] != b"KBGUARD1":
        raise ValueError("not a KBGUARD1 artifact")
    version, entry_size, count, blob_bytes, _ = struct.unpack_from("<HHIII", data, 8)
    if version != 1 or entry_size != 24:
        raise ValueError(f"unsupported KBGUARD version={version} entrySize={entry_size}")
    blob_base = 24 + count * entry_size
    if blob_base + blob_bytes != len(data):
        raise ValueError("invalid KBGUARD offsets")
    rows = []
    for index in range(count):
        _, offset, length, language, action, _, _, _ = struct.unpack_from(
            "<QIHBBHHI", data, 24 + index * entry_size
        )
        if language not in LANGUAGES or action not in ACTIONS:
            raise ValueError(f"unsupported row metadata at index {index}")
        term = data[blob_base + offset:blob_base + offset + length].decode("utf-8")
        rows.append((term, LANGUAGES[language], ACTIONS[action]))
    return sorted(rows, key=lambda row: (row[1], row[0]))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-sha256")
    args = parser.parse_args()
    actual = sha256(args.artifact)
    if args.expected_sha256 and actual != args.expected_sha256.lower():
        raise SystemExit(f"artifact hash mismatch: expected {args.expected_sha256}, got {actual}")
    rows = read_rows(args.artifact)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="") as handle:
        handle.write(HEADER)
        for term, language, action in rows:
            handle.write(
                f"{term}\t{language}\t{action}\trecovered-production-v1\t"
                "internal-reviewed-policy\tapproved\n"
            )
    print(f"wrote {args.output}: {len(rows)} reviewed rows; source sha256={actual}")


if __name__ == "__main__":
    main()
