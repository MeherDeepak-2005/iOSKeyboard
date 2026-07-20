#!/usr/bin/env python3
"""Create the pinned ESDB tier snapshot consumed by build_language_data.py.

The upstream ESDB command line is intentionally not a release-build dependency.
Generate its American-English size-60 and size-70 lists from the pinned source
revision, then run this tool once and review the resulting tracked artifact.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import re
import unicodedata
from pathlib import Path

WORD = re.compile(r"^[a-z']+$")
EXPECTED_COMMIT = "1e5b7d3a72f47a71da5d28686c1dd4b397178485"
EXPECTED_SIZE60_SHA256 = "45a4dd29b86234fbabce26f33272466bb5572db6fdca1470c4f218e6b666a56d"
EXPECTED_SIZE70_SHA256 = "8363339af936f7a0c5100993915d55d3dd1523700b921647b59feae2957cf67b"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalized_words(path: Path) -> set[str]:
    result: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        word = unicodedata.normalize("NFKD", raw.strip()).encode(
            "ascii", "ignore").decode("ascii").lower()
        if WORD.fullmatch(word) and not word.startswith("'") and not word.endswith("'"):
            result.add(word)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--size60", type=Path, required=True)
    parser.add_argument("--size70", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if args.source_commit != EXPECTED_COMMIT:
        raise SystemExit(f"unexpected ESDB revision: {args.source_commit}")
    for path, expected in ((args.size60, EXPECTED_SIZE60_SHA256),
                           (args.size70, EXPECTED_SIZE70_SHA256)):
        actual = sha256(path)
        if actual != expected:
            raise SystemExit(f"checksum mismatch for {path}: {actual}")

    size60 = normalized_words(args.size60)
    size70 = normalized_words(args.size70)
    if not size60 or not size60 <= size70:
        raise SystemExit("ESDB size-60 must be a non-empty subset of size-70")

    rows = ["# ESDB v2 pinned tier snapshot\n", "# word\ttier\n"]
    rows.extend(f"{word}\t{60 if word in size60 else 70}\n"
                for word in sorted(size70))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with bz2.open(args.output, "wt", encoding="utf-8", compresslevel=9) as handle:
        handle.writelines(rows)
    print(f"{args.output}: {len(size60)} size-60, "
          f"{len(size70) - len(size60)} size-70, sha256={sha256(args.output)}")


if __name__ == "__main__":
    main()
