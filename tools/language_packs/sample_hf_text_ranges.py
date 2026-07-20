#!/usr/bin/env python3
"""Deterministically sample a very large Hugging Face text artifact by byte range."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

import requests
from huggingface_hub import hf_hub_url


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _remote_size(session: requests.Session, url: str) -> int:
    response = session.get(url, headers={"Range": "bytes=0-0"}, timeout=60)
    response.raise_for_status()
    content_range = response.headers.get("Content-Range", "")
    if response.status_code != 206 or "/" not in content_range:
        raise RuntimeError("remote host did not honor the byte-range probe")
    return int(content_range.rsplit("/", 1)[1])


def _range_start(seed: bytes, index: int, count: int, total: int,
                 range_bytes: int) -> int:
    lower = total * index // count
    upper = total * (index + 1) // count
    room = upper - lower - range_bytes
    if room < 0:
        raise ValueError("range count/size exceeds the remote artifact")
    digest = hashlib.sha256(seed + index.to_bytes(4, "big")).digest()
    return lower + int.from_bytes(digest[:8], "big") % (room + 1)


def sample(args: argparse.Namespace) -> dict:
    if not 1 <= args.range_count <= 4096:
        raise ValueError("range-count must be in 1...4096")
    if not 4096 <= args.range_bytes <= 8 * 1024 * 1024:
        raise ValueError("range-bytes must be in 4 KiB...8 MiB")
    if args.output.is_symlink() or args.report.is_symlink():
        raise ValueError("refusing to overwrite a symlink")
    if args.source_sha256 and len(args.source_sha256) != 64:
        raise ValueError("source-sha256 must be a 64-character digest")

    url = hf_hub_url(
        args.repository,
        args.filename,
        repo_type="dataset",
        revision=args.revision,
    )
    session = requests.Session()
    session.headers["User-Agent"] = "GlyphLanguagePackBuilder/1"
    total = _remote_size(session, url)
    if args.source_bytes is not None and total != args.source_bytes:
        raise ValueError(f"remote size changed: expected {args.source_bytes}, got {total}")
    if args.range_count * args.range_bytes > total:
        raise ValueError("requested ranges exceed the remote artifact")

    seed = f"{args.repository}\0{args.filename}\0{args.revision}".encode("utf-8")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(f".{args.output.name}.{os.getpid()}.tmp")
    ranges = []
    try:
        with temporary.open("wb") as output:
            for index in range(args.range_count):
                start = _range_start(
                    seed, index, args.range_count, total, args.range_bytes)
                end = start + args.range_bytes - 1
                response = session.get(
                    url,
                    headers={"Range": f"bytes={start}-{end}"},
                    timeout=120,
                )
                response.raise_for_status()
                if response.status_code != 206 or len(response.content) != args.range_bytes:
                    raise RuntimeError(f"invalid byte-range response for {start}-{end}")
                payload = response.content
                first_newline = payload.find(b"\n")
                last_newline = payload.rfind(b"\n")
                if first_newline < 0 or last_newline <= first_newline:
                    raise RuntimeError(f"range {index} contains no complete text line")
                complete = payload[first_newline + 1:last_newline + 1]
                complete.decode("utf-8", errors="strict")
                output.write(complete)
                ranges.append({
                    "index": index,
                    "start": start,
                    "end": end,
                    "completeBytes": len(complete),
                    "sha256": sha256_bytes(complete),
                })
        os.replace(temporary, args.output)
    finally:
        temporary.unlink(missing_ok=True)

    report = {
        "schemaVersion": 1,
        "sampling": "one SHA-256-jittered byte range per equal-size source stratum",
        "source": {
            "repository": args.repository,
            "filename": args.filename,
            "revision": args.revision,
            "bytes": total,
            "sha256": args.source_sha256,
            "url": url,
        },
        "rangeBytes": args.range_bytes,
        "rangeCount": args.range_count,
        "ranges": ranges,
        "output": {
            "path": str(args.output),
            "bytes": args.output.stat().st_size,
            "sha256": file_sha256(args.output),
        },
    }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--filename", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--source-bytes", type=int)
    parser.add_argument("--source-sha256")
    parser.add_argument("--range-count", type=int, default=64)
    parser.add_argument("--range-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    report = sample(parse_args())
    print(json.dumps(report["output"], sort_keys=True))


if __name__ == "__main__":
    main()
