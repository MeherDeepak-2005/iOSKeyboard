#!/usr/bin/env python3
"""Fetch only the release-pinned open inputs; never scrape or acquire paid corpora."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
SOURCES = {
    "esdb": {
        "file": "esdb.tar.gz", "version": "1e5b7d3a72f47a71da5d28686c1dd4b397178485",
        "url": "https://codeload.github.com/en-wl/wordlist/tar.gz/1e5b7d3a72f47a71da5d28686c1dd4b397178485",
        "sha256": "aaecc7a54af576057e30b22a19b78bad011f2181f7e368ff3b736fbecbdfd4d0",
        "license": "MIT-like combined ESDB work; constituent notices retained",
    },
    "wordnet": {
        "file": "wordnet.xml.gz", "version": "2025 core",
        "url": "https://en-word.net/static/english-wordnet-2025.xml.gz",
        "sha256": "9ca6d1dcb75f822fdd66617f7d9da48142ace38dd544d6ad5e2feca1674ad3fe",
        "license": "CC-BY-4.0",
    },
    "masc": {
        "file": "masc.zip", "version": "500K text-only; datasets-2026-09-25",
        "url": "https://github.com/nancyide/anc-website/releases/download/datasets-2026-09-25/masc_500k_texts.zip",
        "sha256": "0c3f1fd3314ee5ec09830d6f6b217c19a6899d1cabd22c42264578c3348b2d01",
        "license": "OANC/MASC unrestricted usage and redistribution, including commercial use",
        "terms_url": "https://anc.org/data/oanc/",
    },
    "frequency": {
        "file": "frequency-en.txt", "version": "2018; 525f9b560de45753a5ea01069454e72e9aa541c6",
        "url": "https://raw.githubusercontent.com/hermitdave/FrequencyWords/525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/en/en_full.txt",
        "sha256": "7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506",
        "license": "CC-BY-SA-4.0",
    },
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def verified(path: Path, expected: str) -> Path:
    if digest(path) != expected:
        raise ValueError(f"checksum mismatch: {path}")
    return path


def fetch(source: dict, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / source["file"]
    if path.exists():
        return verified(path, source["sha256"])
    temporary = path.with_suffix(path.suffix + ".part")
    try:
        request = urllib.request.Request(source["url"], headers={"User-Agent": "XploreeVocabularyBuilder/1.0"})
        with urllib.request.urlopen(request, timeout=60) as response, temporary.open("wb") as out:
            while block := response.read(1 << 20):
                out.write(block)
        verified(temporary, source["sha256"])
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def cleanup(cache: Path) -> None:
    """Delete only this tool's recognized, hash-matched downloads, never a tree."""
    for source in SOURCES.values():
        path = cache / source["file"]
        if path.exists():
            verified(path, source["sha256"]).unlink()
    if cache.is_dir() and not any(cache.iterdir()):
        cache.rmdir()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / "tools/.cache/vocabulary")
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    if args.cleanup:
        cleanup(args.cache)
    else:
        for name, source in SOURCES.items():
            path = fetch(source, args.cache)
            print(f"{name}: {path.name}, {path.stat().st_size:,} bytes, SHA-256 verified", flush=True)


if __name__ == "__main__":
    main()
