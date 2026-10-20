#!/usr/bin/env python3
"""Prepare bounded, provenance-preserving English snapshots from pinned sources.

This is the offline admission step, not a runtime loader. Baseline frequencies are
untouched; new terms receive conservative priors. MASC is split by document family
before selecting words/counts, and single-occurrence corpus n-grams are not shipped.
"""
from __future__ import annotations

import argparse
import bz2
from collections import Counter, defaultdict
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import build_language_data as builder
from fetch_sources import SOURCES, digest, verified

MASC_MIN_COUNT = 5  # Fits the complete 14 MB iPhone extension budget, not just the pack cap.
DIALECTS = {"A": "en-US", "B": "en-GB-ise", "Z": "en-GB-ize", "C": "en-CA", "D": "en-AU"}
RAW_TOKEN = re.compile(r"\w+(?:'\w+)*", re.UNICODE)
SENTENCE_BREAK = re.compile(r"[.!?]+(?:[\"'’”)]*)\s+|\r?\n+")
CURATED = Path(__file__).with_name("curated_terms.tsv")
CONTEXTS = Path(__file__).with_name("curated_contexts.jsonl")


def normalized(word: str) -> str:
    return unicodedata.normalize("NFC", word).replace("’", "'").replace("‘", "'").lower()


def eligible(word: str, *, curated=False) -> bool:
    return bool(builder.WORD.fullmatch(word)) and not word.startswith("'") \
        and not word.endswith("'") and word not in builder.EXCLUDE \
        and (len(word) >= (2 if curated else 3)) and len(word) <= 32 \
        and (curated or "'" not in word)


def tokenize(text: str) -> list[str | None]:
    """Unsupported lexical spans stay boundaries; never join across 2026/URLs/etc."""
    text = unicodedata.normalize("NFC", text).replace("’", "'").replace("‘", "'")
    # Hide URLs/addresses and compound/digit tokens as one unknown lexical span.
    text = re.sub(r"(?:https?://|www\.)\S+|\S+@\S+|\w+(?:[-/]\w+)+", " UNKNOWN_BOUNDARY ", text)
    return [key if builder.WORD.fullmatch(key) and len(key) <= 32 else None
            for raw in RAW_TOKEN.findall(text) if (key := normalized(raw))]


def document_family(name: str) -> str:
    path = PurePosixPath(name)
    stem = re.sub(r"(?:[-_]\d+)+$", "", path.stem)
    return str(path.parent / stem)


def document_split(name: str) -> str:
    value = int(hashlib.sha256(document_family(name).encode()).hexdigest()[:8], 16)
    return "test" if value % 5 == 0 else "train"


def masc_documents(archive: Path):
    """Read archive members directly; never extract source-controlled paths."""
    with zipfile.ZipFile(archive) as z:
        for name in sorted(z.namelist()):
            path = PurePosixPath(name)
            if ".." in path.parts or path.is_absolute():
                raise ValueError(f"unsafe corpus member: {name}")
            if not name.endswith(".txt"):
                continue
            # Each physical line/sentence is an independent boundary. No dialogue
            # joins between lines, files, contributors or document train/test splits.
            text = z.read(name).decode("utf-8-sig", errors="strict")
            genre = path.parts[2] if len(path.parts) > 3 else "unknown"
            yield name, genre, [tokens for sentence in SENTENCE_BREAK.split(text)
                                if len(tokens := tokenize(sentence)) >= 2]


def add_evidence(catalog: dict, form: str, source: str, **metadata):
    entry = catalog.setdefault(form, {"word": form, "sources": set(), "locales": set(), "pos": set(), "tier": 99})
    entry["sources"].add(source)
    if "locale" in metadata:
        entry["locales"].add(metadata["locale"])
    if "pos" in metadata:
        entry["pos"].add(metadata["pos"])
    if "tier" in metadata:
        entry["tier"] = min(entry["tier"], metadata["tier"])


def import_esdb(archive: Path, catalog: dict) -> dict:
    stats = {}
    with tempfile.TemporaryDirectory(prefix="xploree-esdb-") as temporary:
        with tarfile.open(archive) as tf:
            tf.extractall(temporary, filter="data")
        source = next(Path(temporary).iterdir())
        result = subprocess.run([sys.executable, "combine.py", "create-db", "scowl.db"],
                                cwd=source, capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"ESDB database build failed: {result.stderr[-3000:]}")
        copyright_text = "\n".join(line.rstrip() for line in (source / "Copyright").read_text(encoding="utf-8").splitlines()) + "\n"
        (Path(__file__).parent / "ESDB_COPYRIGHT.md").write_text(copyright_text, encoding="utf-8")
        for dialect, locale in DIALECTS.items():
            for tier in (60, 70):
                result = subprocess.run([sys.executable, "scowl", "word-list", str(tier), dialect,
                                         "1", "--nosuggest"], cwd=source,
                                        capture_output=True, text=True, check=True)
                accepted = 0
                for raw in result.stdout.splitlines():
                    word = normalized(raw)
                    # Proper-name casing, accents and unsupported forms are not
                    # destroyed to create apparently valid ASCII candidates.
                    if raw != raw.lower() or not eligible(word):
                        continue
                    add_evidence(catalog, word, "esdb", locale=locale, tier=tier)
                    accepted += 1
                stats[f"{locale}:{tier}"] = accepted
        db = sqlite3.connect(source / "scowl.db")
        try:
            for word, pos in db.execute("select distinct word, base_pos from scowl_v0 where size <= 70"):
                key = normalized(word)
                if key in catalog:
                    catalog[key]["pos"].add(pos)
        finally:
            db.close()
    return stats


def import_wordnet(path: Path, catalog: dict) -> int:
    count = 0
    with gzip.open(path, "rb") as stream:
        for _, entry in ET.iterparse(stream, events=("end",)):
            if entry.tag.rsplit("}", 1)[-1] != "LexicalEntry":
                continue
            for element in entry:
                tag = element.tag.rsplit("}", 1)[-1]
                if tag not in {"Lemma", "Form"}:
                    continue
                raw = element.get("writtenForm", "")
                key = normalized(raw)
                if raw != raw.lower() or not eligible(key):
                    continue
                add_evidence(catalog, key, "wordnet", pos=element.get("partOfSpeech", ""))
                count += 1
            entry.clear()
    return count


def load_frequencies(path: Path) -> dict[str, int]:
    frequencies = {}
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            fields = line.split()
            if len(fields) == 2 and fields[1].isdigit():
                # Never transliterate or merge incompatible Unicode spellings.
                word = normalized(fields[0])
                if builder.WORD.fullmatch(word):
                    frequencies[word] = max(frequencies.get(word, 0), int(fields[1]))
    return frequencies


def curated_terms() -> dict:
    entries = {}
    for index, line in enumerate(CURATED.read_text().splitlines(), 1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3:
            raise ValueError(f"bad curated term row {index}")
        word, register, prior = fields
        if word != normalized(word) or not eligible(word, curated=True) or word in entries \
                or not prior.isdigit() or not 1 <= int(prior) <= 5000:
            raise ValueError(f"invalid curated term row {index}: {word}")
        entries[word] = {"register": register, "frequency_prior": int(prior)}
    return entries


def select_entries(catalog, base, frequency, corpus_counts, document_counts, limit):
    curated = curated_terms()
    for word in curated:
        add_evidence(catalog, word, "project")
    candidates = []
    for word, evidence in catalog.items():
        if word in base:
            continue
        raw = frequency.get(word, 0)
        observed = corpus_counts[word]
        documents = document_counts[word]
        if word in curated:
            priority = 0
            prior = curated[word]["frequency_prior"]
            register = curated[word]["register"]
        else:
            # Source validity and independent usage evidence are separate gates.
            # WordNet-only forms need stronger evidence than tier-60 spellings.
            threshold = 100 if evidence["tier"] <= 60 else 500
            if raw < threshold and not (observed >= 5 and documents >= 3):
                continue
            regional = "en-US" not in evidence["locales"] and bool(evidence["locales"])
            priority = 1 if regional and raw >= 500 else 2
            prior = min(20_000, max(50, raw))
            register = "regional" if regional else "general"
        # No source raw count is added to the enormous subtitle scale. Corpus
        # evidence helps admission only; new unigram priors are explicitly capped.
        candidates.append({"word": word, "frequency_prior": prior, "register": register,
            "sources": sorted(evidence["sources"]), "locales": sorted(evidence["locales"]),
            "pos": sorted(p for p in evidence["pos"] if p),
            "esdb_tier": evidence["tier"] if evidence["tier"] != 99 else None,
            "frequencywords_count": raw, "masc_train_count": observed,
            "masc_train_documents": documents, "selection_priority": priority})
    candidates.sort(key=lambda e: (e["selection_priority"], -e["frequencywords_count"],
                                   -e["masc_train_count"], e["word"]))
    return candidates[:limit], len(candidates)


def count_contexts(sentences, vocabulary):
    counts = {2: Counter(), 3: Counter()}
    for sentence in sentences:
        tokens = [word if word in vocabulary else None for word in sentence]
        for n in (2, 3):
            for index in range(len(tokens) - n + 1):
                key = tuple(tokens[index:index+n])
                if all(word is not None for word in key):
                    counts[n][key] += 1
    return counts


def context_groups(counts, minimum, maximum):
    # Retain true per-context totals even when some successors are not serialized.
    selected = sorted((key, count) for key, count in counts.items() if count >= minimum)
    selected.sort(key=lambda item: (-item[1], item[0]))
    kept = selected[:maximum]
    totals = Counter()
    for key, count in counts.items():
        totals[key[:-1]] += count
    groups = defaultdict(list)
    for key, count in kept:
        groups[key[:-1]].append([key[-1], count])
    return [{"context": list(key), "total": totals[key],
             "entries": sorted(groups[key], key=lambda item: (-item[1], item[0]))}
            for key in sorted(groups)]


def write_json_bz2(path: Path, value) -> dict:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    path.write_bytes(bz2.compress(payload, compresslevel=9))
    return {"path": str(path.relative_to(ROOT)), "sha256": digest(path), "bytes": path.stat().st_size}


def prepare(cache: Path, output: Path, limit: int):
    paths = {name: verified(cache / source["file"], source["sha256"]) for name, source in SOURCES.items()}
    builder.CACHE.mkdir(parents=True, exist_ok=True)
    frequency_cache = builder.CACHE / "en_full.txt"
    if not frequency_cache.exists():
        shutil.copyfile(paths["frequency"], frequency_cache)
    verified(frequency_cache, SOURCES["frequency"]["sha256"])
    # This reconstructs the original source selection, regardless of which pack
    # is currently installed. It never uses a previously expanded pack as input.
    base_vocab = builder.merge_contractions(builder.build_vocab())
    base = dict(base_vocab)
    if len(base) + limit > builder.EMPTY16 - 1:
        raise ValueError("requested vocabulary expansion exceeds v5 ID capacity")
    catalog = {}
    esdb_stats = import_esdb(paths["esdb"], catalog)
    wordnet_count = import_wordnet(paths["wordnet"], catalog)
    frequency = load_frequencies(paths["frequency"])
    documents = list(masc_documents(paths["masc"]))
    train, heldout, used = [], [], set()
    train_counts, doc_counts = Counter(), Counter()
    doc_manifest = []
    for name, genre, sentences in documents:
        split = document_split(name)
        destination = train if split == "train" else heldout
        admitted = []
        for tokens in sentences:
            key = tuple(tokens)
            if key in used:
                continue
            used.add(key)
            admitted.append(tokens)
        destination.extend({"document": name, "genre": genre, "tokens": tokens} for tokens in admitted)
        if split == "train":
            words = [word for sentence in admitted for word in sentence if word is not None]
            train_counts.update(words)
            doc_counts.update(set(words))
        doc_manifest.append({"document": name, "genre": genre, "family": document_family(name),
                             "split": split, "sentences": len(admitted)})
    selected, eligible_count = select_entries(catalog, base, frequency, train_counts, doc_counts, limit)
    vocab = set(base) | {entry["word"] for entry in selected}
    masc = count_contexts((row["tokens"] for row in train), vocab)
    authored = [json.loads(line) for line in CONTEXTS.read_text().splitlines() if line.strip()]
    owned = count_contexts((tokenize(row["text"]) for row in authored), vocab)
    context_snapshot = {"schema_version": 1, "sources": {
        "masc": {"min_count": MASC_MIN_COUNT, "bigrams": context_groups(masc[2], MASC_MIN_COUNT, 25_000),
                 "trigrams": context_groups(masc[3], MASC_MIN_COUNT, 20_000)},
        "project": {"kind": "authored_example_priors_not_observed_corpus_frequencies",
                    "bigrams": context_groups(owned[2], 1, 1000),
                    "trigrams": context_groups(owned[3], 1, 1000)}}}
    output.mkdir(parents=True, exist_ok=True)
    artifacts = {
        "vocabulary": write_json_bz2(output / "english-expansion-v1.json.bz2",
            {"schema_version": 1, "baseline_words": len(base), "entries": selected}),
        "contexts": write_json_bz2(output / "english-contexts-v1.json.bz2", context_snapshot),
        "heldout": write_json_bz2(output / "english-masc-heldout-v1.json.bz2",
            {"schema_version": 1, "split_policy": "SHA256(document_family) mod 5 == 0",
             "limitation": "Document-family split; author identities are unavailable in this text-only archive.",
             "sentences": heldout}),
    }
    manifest = {"schema_version": 1, "version": "english-expansion-v1", "release_eligible": True,
        "scope": "ASCII English v5 expansion; no paid/research-only sources",
        "baseline_words": len(base), "additional_words": len(selected),
        "selection": {"maximum_additions": limit, "eligible_candidates": eligible_count,
            "frequency_prior_cap": 20_000, "wordnet_only_frequency_minimum": 500,
            "tier60_frequency_minimum": 100, "alternative_masc_count": 5,
            "alternative_masc_document_count": 3},
        "sources": {name: source | {"release_eligible": True} for name, source in SOURCES.items()},
        "project_inputs": [{"path": str(path.relative_to(ROOT)), "sha256": digest(path)}
                           for path in [CURATED, CONTEXTS]],
        "artifacts": artifacts,
        "source_statistics": {"esdb_exports": esdb_stats, "wordnet_eligible_entries": wordnet_count,
            "masc_documents": len(documents), "train_sentences": len(train), "test_sentences": len(heldout),
            "train_tokens": sum(len(row["tokens"]) for row in train),
            "selected_word_sources": dict(Counter(s for entry in selected for s in entry["sources"])),
            "selected_registers": dict(Counter(entry["register"] for entry in selected))},
        "documents": doc_manifest,
        "not_enabled": {"COCA": "Requires embedded commercial distribution rights",
            "GloWbE": "Requires embedded commercial distribution rights",
            "NUS_SMS": "Commercial rights unresolved", "BNC2014": "Research-only public terms",
            "Kaikki": "Optional later adapter; attribution/share-alike and register review required",
            "wordfreq": "Optional calibration; source overlap/redistribution review required",
            "Gutenberg": "Optional literary stream; per-title territorial selection required",
            "PMC": "Optional science-domain stream; article license filtering required",
            "GeoNames": "Optional entity layer; separate correction policy required"}}
    path = output / "english-expansion-v1.manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"manifest": str(path), "additional_words": len(selected),
                      "source_statistics": manifest["source_statistics"]}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", type=Path, default=ROOT / "tools/.cache/vocabulary")
    parser.add_argument("--output", type=Path, default=ROOT / "tools/data")
    parser.add_argument("--limit", type=int, default=4000)
    args = parser.parse_args()
    if not 1 <= args.limit <= 4000:
        parser.error("--limit must be between 1 and 4000")
    prepare(args.cache, args.output, args.limit)


if __name__ == "__main__":
    main()
