"""Tokenize the corpora into NSS training shards.

    python -m nss.build_corpus [--sources tatoeba wikitext soda] [--chat chat.txt]
                               [--stock-name-keep 0.25] [--out data-v2] [--workers 6]

Writes data/<source>.<split>.tokens.npy (uint16: <bos> w1 .. wn <eos> per sentence),
data/<source>.<split>.offsets.npy (int64 sentence starts plus the end) and
data/corpus.json (input hashes, counts, <unk> rates and the lexicon share of <unk>).

Splits hash the document key: 0.5% valid, 0.5% test. Exact duplicate sentences inside
a source are dropped. Tatoeba's stock characters (Tom 23% and Mary 8% of sentences)
would teach the model that "tom" follows "talking to"; nine in ten of them become
<unk>, the token any other name is, keeping one in ten as the real word. Mapped alone,
that makes 19% of Tatoeba's sentence-initial words <unk> (real text: about 10%), so
--stock-name-keep 0.25 also keeps only a quarter of the sentences that name them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from multiprocessing import Pool
from pathlib import Path

import numpy as np

from . import DATA, DEFAULT_LANGDATA, DEFAULT_VOCAB, REPO
from . import sources
from .lexicon import Lexicon
from .text import sentences
from .vocab import BOS, EOS, UNK, Vocabulary, sha256

SPLITS = ("train", "valid", "test")
STOCK_NAMES = {"tom", "mary"}
stock_name_keep = 1.0

_vocab: Vocabulary | None = None
_lexicon: Lexicon | None = None


def bucket(key: str) -> int:
    return int.from_bytes(hashlib.sha256(key.encode("utf-8")).digest()[:4], "little")


def split_of(key: str) -> str:
    slot = bucket(key) % 200
    return "valid" if slot == 0 else "test" if slot == 1 else "train"


def _init(vocab_path: str, langdata_path: str) -> None:
    global _vocab, _lexicon
    _vocab = Vocabulary.load(Path(vocab_path))
    _lexicon = Lexicon.load(Path(langdata_path))


def _encode(job: tuple[str, str, str]) -> tuple[str, np.ndarray, np.ndarray, dict]:
    """(source, key, text) -> (split, tokens, sentence lengths, stats)."""
    source, key, text = job
    stats = {"sentences": 0, "words": 0, "unk": 0, "unk_lexicon": 0, "stock_names": 0}
    ids, lengths = [], []
    for index, words in enumerate(sentences(text)):
        encoded = [BOS]
        for position, word in enumerate(words):
            token = _vocab.id(word)
            if source == "tatoeba" and word in STOCK_NAMES and bucket(f"{key}|{index}|{position}") % 10:
                token = UNK
                stats["stock_names"] += 1
            elif token == UNK and word.strip("'") in _lexicon:
                stats["unk_lexicon"] += 1
            stats["unk"] += token == UNK
            encoded.append(token)
        encoded.append(EOS)
        stats["sentences"] += 1
        stats["words"] += len(words)
        ids.extend(encoded)
        lengths.append(len(encoded))
    return split_of(key), np.asarray(ids, np.uint16), np.asarray(lengths, np.int64), stats


def _documents(source: str, chat: Path | None):
    seen: set[bytes] = set()
    if source == "tatoeba":
        for key, text in sources.tatoeba():
            words = [w for s in sentences(text) for w in s]
            if stock_name_keep < 1 and STOCK_NAMES.intersection(words) and bucket(f"stock|{key}") % 1000 >= stock_name_keep * 1000:
                continue
            digest = hashlib.sha256(" ".join(words).encode()).digest()[:12]
            if digest not in seen:
                seen.add(digest)
                yield source, key, text
    elif source == "soda":
        for key, text in sources.soda():
            yield source, key, text
    elif source == "wikitext":
        for key, text in sources.wikitext():
            yield source, key, text
    elif source == "chat":
        for key, text in sources.plain_text(chat):
            digest = hashlib.sha256(key.lower().encode()).digest()[:12]
            if digest not in seen:
                seen.add(digest)
                yield source, key, text


def build_source(source: str, out: Path, workers: int, chat: Path | None) -> dict:
    parts = {split: ([], []) for split in SPLITS}
    totals = {split: {"sentences": 0, "words": 0, "unk": 0, "unk_lexicon": 0, "stock_names": 0} for split in SPLITS}
    with Pool(workers, initializer=_init, initargs=(str(DEFAULT_VOCAB), str(DEFAULT_LANGDATA))) as pool:
        for split, ids, lengths, stats in pool.imap(_encode, _documents(source, chat), chunksize=256):
            if len(lengths):
                parts[split][0].append(ids)
                parts[split][1].append(lengths)
                for name, value in stats.items():
                    totals[split][name] += value
    summary = {}
    for split in SPLITS:
        ids = np.concatenate(parts[split][0]) if parts[split][0] else np.zeros(0, np.uint16)
        lengths = np.concatenate(parts[split][1]) if parts[split][1] else np.zeros(0, np.int64)
        offsets = np.concatenate([[0], np.cumsum(lengths)]).astype(np.int64)
        np.save(out / f"{source}.{split}.tokens.npy", ids)
        np.save(out / f"{source}.{split}.offsets.npy", offsets)
        t = totals[split]
        summary[split] = {**t, "tokens": int(len(ids)),
                          "unk_rate": t["unk"] / max(t["words"], 1),
                          "unk_lexicon_share": t["unk_lexicon"] / max(t["unk"], 1)}
        print(f"{source}.{split}: {t['sentences']:,} sentences, {t['words']:,} words, "
              f"unk {summary[split]['unk_rate']:.2%}, lexicon share of unk "
              f"{summary[split]['unk_lexicon_share']:.2%}", flush=True)
    return summary


def build_masc(out: Path, vocabulary: Vocabulary, lexicon: Lexicon) -> dict:
    """MASC held-out: test only. None (an unrepresentable token) becomes an unscored <unk>."""
    ids, lengths, spoken, scored = [], [], [], []
    stats = {"sentences": 0, "words": 0, "unk": 0, "unk_lexicon": 0}
    for document, tokens, _ in sources.masc_heldout():
        encoded, mask = [BOS], [True]
        for token in tokens:
            if token is None:
                encoded.append(UNK)
                mask.append(False)
                continue
            token_id = vocabulary.id(token)
            encoded.append(token_id)
            mask.append(True)
            stats["words"] += 1
            stats["unk"] += token_id == UNK
            stats["unk_lexicon"] += token_id == UNK and token.strip("'") in lexicon
        encoded.append(EOS)
        mask.append(True)
        stats["sentences"] += 1
        ids.extend(encoded)
        scored.extend(mask)
        lengths.append(len(encoded))
        spoken.append(document.split("/")[1] == "spoken")
    np.save(out / "masc.test.tokens.npy", np.asarray(ids, np.uint16))
    np.save(out / "masc.test.offsets.npy", np.concatenate([[0], np.cumsum(lengths)]).astype(np.int64))
    np.save(out / "masc.test.scored.npy", np.asarray(scored, bool))
    np.save(out / "masc.test.spoken.npy", np.asarray(spoken, bool))
    summary = {**stats, "tokens": len(ids), "unk_rate": stats["unk"] / max(stats["words"], 1),
               "unk_lexicon_share": stats["unk_lexicon"] / max(stats["unk"], 1)}
    print(f"masc.test: {stats['sentences']:,} sentences, {stats['words']:,} words, "
          f"unk {summary['unk_rate']:.2%}", flush=True)
    return {"test": summary}


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, default=DATA)
    parser.add_argument("--sources", nargs="+", default=["tatoeba", "wikitext"])
    parser.add_argument("--chat", type=Path, help="plain-text messaging corpus, one message per line")
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--stock-name-keep", type=float, default=1.0,
                        help="share of Tatoeba sentences naming Tom or Mary to keep")
    args = parser.parse_args(argv)
    global stock_name_keep
    stock_name_keep = args.stock_name_keep
    args.out.mkdir(parents=True, exist_ok=True)
    selected = list(args.sources) + (["chat"] if args.chat else [])

    vocabulary = Vocabulary.load(DEFAULT_VOCAB)
    lexicon = Lexicon.load(DEFAULT_LANGDATA)
    manifest_path = args.out / "corpus.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"sources": {}}
    if manifest.get("vocabulary_sha256", vocabulary.sha256) != vocabulary.sha256:
        sys.exit("data/ was built with another vocabulary; remove it first")
    manifest.update({"schema_version": 1, "vocabulary": str(DEFAULT_VOCAB.relative_to(REPO)),
                     "vocabulary_sha256": vocabulary.sha256, "langdata_sha256": lexicon.sha256,
                     "split_policy": "sha256(document key) mod 200: 0 valid, 1 test, else train",
                     "stock_names": "tatoeba tom/mary -> <unk> unless sha256(key|sentence|position) mod 10 == 0",
                     "stock_name_sentences_kept": stock_name_keep})
    inputs = {"tatoeba": [sources.TATOEBA], "wikitext": sources.WIKITEXT, "soda": sources.SODA,
              "chat": [args.chat] if args.chat else []}
    for source in selected:
        summary = build_source(source, args.out, args.workers, args.chat)
        manifest["sources"][source] = {"inputs": [{"path": p.name, "sha256": sha256(p)} for p in inputs[source]],
                                       "splits": summary}
    manifest["sources"]["masc"] = {"inputs": [{"path": sources.MASC_HELDOUT.name, "sha256": sha256(sources.MASC_HELDOUT)}],
                                   "splits": build_masc(args.out, vocabulary, lexicon)}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
