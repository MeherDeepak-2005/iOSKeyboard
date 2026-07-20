#!/usr/bin/env python3
"""Print the exact shipped language-pack footprint and inventory as JSON."""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


def size_record(path: Path) -> dict[str, int | float | str]:
    size = path.stat().st_size
    return {
        "path": str(path),
        "bytes": size,
        "mib": round(size / (1024 * 1024), 3),
    }


def english(path: Path) -> dict:
    data = path.read_bytes()
    magic, version, words, bigram_contexts, bigram_entries, trigram_contexts, \
        trigram_entries, trie_nodes, starters = struct.unpack_from("<9I", data)
    if magic != 0x4B424C4D:
        raise ValueError(f"{path}: invalid KBLM header")
    return size_record(path) | {
        "format": f"KBLM-v{version}",
        "words": words,
        "bigram_contexts": bigram_contexts,
        "bigram_continuations": bigram_entries,
        "trigram_contexts": trigram_contexts,
        "trigram_continuations": trigram_entries,
        "trie_nodes": trie_nodes,
        "sentence_starters": starters,
    }


def telugu(path: Path) -> dict:
    data = path.read_bytes()
    values = struct.unpack_from("<4s18I", data)
    if values[0] != b"KBTD":
        raise ValueError(f"{path}: invalid KBTD header")
    version, words, trie_nodes, trie_edges, bigram_contexts, bigram_entries, \
        trigram_contexts, trigram_entries = values[1:9]
    return size_record(path) | {
        "format": f"KBTD-v{version}",
        "words": words,
        "trie_nodes": trie_nodes,
        "trie_edges": trie_edges,
        "bigram_contexts": bigram_contexts,
        "bigram_continuations": bigram_entries,
        "trigram_contexts": trigram_contexts,
        "trigram_continuations": trigram_entries,
    }


def tenglish(path: Path) -> dict:
    data = path.read_bytes()
    values = struct.unpack_from("<4s15I", data)
    if values[0] != b"KBXL":
        raise ValueError(f"{path}: invalid KBXL header")
    version, key_count, mappings, key_offset, variant_offset, blob_offset, _, \
        bigram_offset, bigram_contexts, bigram_entry_offset, bigram_entries, \
        trigram_offset, trigram_contexts, trigram_entry_offset, trigram_entries = values[1:]
    if version != 3 or key_offset != 64:
        raise ValueError(f"{path}: unsupported KBXL version {version}")
    outputs: set[str] = set()
    for index in range(mappings):
        relative, length, _, _ = struct.unpack_from(
            "<IHHf", data, variant_offset + index * 12)
        outputs.add(data[blob_offset + relative:blob_offset + relative + length]
                    .decode("utf-8"))
    expected_offsets = (
        bigram_offset <= bigram_entry_offset <= trigram_offset
        <= trigram_entry_offset <= len(data)
    )
    if not expected_offsets:
        raise ValueError(f"{path}: invalid KBXL LM offsets")
    keys: list[str] = []
    for index in range(key_count):
        relative, length, _, _ = struct.unpack_from(
            "<IHHI", data, key_offset + index * 12)
        keys.append(data[blob_offset + relative:blob_offset + relative + length]
                    .decode("utf-8"))

    starters: list[dict[str, int | str]] = []
    for index in range(bigram_contexts):
        context, first, count = struct.unpack_from(
            "<HII", data, bigram_offset + index * 10)
        if context != 0xFFFF:
            continue
        for continuation in range(first, first + min(count, 10)):
            word_id, frequency = struct.unpack_from(
                "<HI", data, bigram_entry_offset + continuation * 6)
            if word_id < len(keys):
                starters.append({"word": keys[word_id], "count": frequency})
        break

    probes: dict[str, list[str]] = {}
    for query in ("idhi", "idi", "anthe", "ante"):
        try:
            key_index = keys.index(query)
        except ValueError:
            probes[query] = []
            continue
        _, _, variant_count, first_variant = struct.unpack_from(
            "<IHHI", data, key_offset + key_index * 12)
        values: list[str] = []
        for offset in range(variant_count):
            relative, length, _, _ = struct.unpack_from(
                "<IHHf", data, variant_offset + (first_variant + offset) * 12)
            values.append(data[blob_offset + relative:blob_offset + relative + length]
                          .decode("utf-8"))
        probes[query] = values
    return size_record(path) | {
        "format": f"KBXL-v{version}",
        "roman_keys": key_count,
        "transliteration_mappings": mappings,
        "unique_telugu_outputs": len(outputs),
        "bigram_contexts": bigram_contexts,
        "bigram_continuations": bigram_entries,
        "trigram_contexts": trigram_contexts,
        "trigram_continuations": trigram_entries,
        "corpus_starters": starters,
        "reviewed_alias_probes": probes,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[2])
    parser.add_argument("--language-root", type=Path,
                        help="directory containing alternate Telugu pack binaries")
    args = parser.parse_args()
    root = args.root.resolve()
    language_root = (args.language_root.resolve() if args.language_root
                     else root / "keyboard")
    packs = {
        "english": english(root / "keyboard/langdata.bin"),
        "telugu_native": telugu(language_root / "telugu_langdata.bin"),
        "tenglish": tenglish(language_root / "tenglish_lexicon.bin"),
    }
    total = sum(int(pack["bytes"]) for pack in packs.values())
    print(json.dumps({
        "packs": packs,
        "total_bytes": total,
        "total_mib": round(total / (1024 * 1024), 3),
    }, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
