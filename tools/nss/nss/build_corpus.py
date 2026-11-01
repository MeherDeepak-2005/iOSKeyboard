"""Tokenize the corpora into NSS training shards.

    python -m nss.build_corpus [--sources tatoeba wikitext soda] [--chat chat.txt]
                               [--stock-name-keep 0.25] [--name-unk 0.9] [--out data-v2] [--workers 6]

Writes data/<source>.<split>.tokens.npy (uint16: <bos> w1 .. wn <eos> per sentence),
data/<source>.<split>.offsets.npy (int64 sentence starts plus the end) and
data/corpus.json (input hashes, counts, <unk> rates and the lexicon share of <unk>).

Splits hash the document key: 0.5% valid, 0.5% test. Exact duplicate sentences inside
a source are dropped. Tatoeba's stock characters (Tom 23% and Mary 8% of sentences)
would teach the model that "tom" follows "talking to"; nine in ten of them become
<unk>, the token any other name is, keeping one in ten as the real word. Mapped alone,
that makes 19% of Tatoeba's sentence-initial words <unk> (real text: about 10%), so
--stock-name-keep 0.25 also keeps only a quarter of the sentences that name them.

--name-unk P does the same for every name and place the vocabulary knows: a word the
sources write capitalized inside sentences at least 90% of the time (sampled from one
document in 20, at least 10 times; not "I", titles, all-capitals or calendar words) becomes <unk> with
probability P wherever it is written capitalized or opens a sentence. Names outside the
vocabulary are <unk> already, so the model learns that <unk> is likely in every slot
names take ("talking to", "call", "meet ... at"), which the decoder uses to leave typed
names alone. The words chosen are written to <out>/names.tsv.
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
from .text import cased_sentences, sentences
from .vocab import BOS, EOS, UNK, Vocabulary, sha256

SPLITS = ("train", "valid", "test")
STOCK_NAMES = {"tom", "mary"}
stock_name_keep = 1.0
NOT_NAMES = {"i", "i'm", "i'll", "i've", "i'd", "monday", "tuesday", "wednesday", "thursday", "friday",
             "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
             "august", "september", "october", "november", "december", "mr", "mrs", "ms", "dr", "st",
             "jr", "sr", "god", "lord", "christmas"}
name_unk = 0.0
_names: frozenset[str] = frozenset()

_vocab: Vocabulary | None = None
_lexicon: Lexicon | None = None


def bucket(key: str) -> int:
    return int.from_bytes(hashlib.sha256(key.encode("utf-8")).digest()[:4], "little")


def split_of(key: str) -> str:
    slot = bucket(key) % 200
    return "valid" if slot == 0 else "test" if slot == 1 else "train"


def _init(vocab_path: str, langdata_path: str, names: frozenset[str] = frozenset(), unk_share: float = 0.0) -> None:
    global _vocab, _lexicon, _names, name_unk
    _vocab = Vocabulary.load(Path(vocab_path))
    _lexicon = Lexicon.load(Path(langdata_path))
    _names, name_unk = names, unk_share


def _encode(job: tuple[str, str, str]) -> tuple[str, np.ndarray, np.ndarray, dict]:
    """(source, key, text) -> (split, tokens, sentence lengths, stats)."""
    source, key, text = job
    stats = {"sentences": 0, "words": 0, "unk": 0, "unk_lexicon": 0, "stock_names": 0, "names": 0}
    ids, lengths = [], []
    for index, cased in enumerate(cased_sentences(text)):
        words = [word for word, _ in cased]
        encoded = [BOS]
        for position, (word, capitalized) in enumerate(cased):
            token = _vocab.id(word)
            if source == "tatoeba" and word in STOCK_NAMES and bucket(f"{key}|{index}|{position}") % 10:
                token = UNK
                stats["stock_names"] += 1
            elif (token != UNK and word in _names and (capitalized or position == 0)
                  and bucket(f"name|{key}|{index}|{position}") % 1000 < name_unk * 1000):
                token = UNK
                stats["names"] += 1
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


def name_set(selected: list[str], chat: Path | None, vocabulary: Vocabulary, sample: int = 20,
             minimum: int = 10, ratio: float = 0.9) -> dict[str, tuple[int, int]]:
    """Vocabulary words written capitalized inside sentences at least `ratio` of the time
    (one document in `sample`): word -> (capitalized, occurrences)."""
    counts: dict[str, list[int]] = {}
    for source in selected:
        for _, key, text in _documents(source, chat):
            if bucket(f"names|{key}") % sample:
                continue
            for cased in cased_sentences(text):
                for word, capitalized in cased[1:]:
                    if word not in NOT_NAMES and vocabulary.id(word) != UNK:
                        count = counts.setdefault(word, [0, 0])
                        count[0] += capitalized
                        count[1] += 1
    return {word: (c[0], c[1]) for word, c in counts.items() if c[1] >= minimum and c[0] >= ratio * c[1]}


def build_source(source: str, out: Path, workers: int, chat: Path | None, names: frozenset[str] = frozenset()) -> dict:
    parts = {split: ([], []) for split in SPLITS}
    totals = {split: {"sentences": 0, "words": 0, "unk": 0, "unk_lexicon": 0, "stock_names": 0, "names": 0} for split in SPLITS}
    with Pool(workers, initializer=_init, initargs=(str(DEFAULT_VOCAB), str(DEFAULT_LANGDATA), names, name_unk)) as pool:
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
    parser.add_argument("--name-unk", type=float, default=0.0,
                        help="share of the vocabulary's name and place occurrences that become <unk>")
    args = parser.parse_args(argv)
    global stock_name_keep, name_unk
    stock_name_keep, name_unk = args.stock_name_keep, args.name_unk
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
    names: frozenset[str] = frozenset()
    if name_unk > 0:
        found = name_set(selected, args.chat, vocabulary)
        (args.out / "names.tsv").write_text("".join(f"{w}\t{c}\t{n}\n" for w, (c, n) in sorted(found.items(), key=lambda x: -x[1][1])))
        names = frozenset(found)
        print(f"{len(names):,} vocabulary names and places -> <unk> with probability {name_unk}", flush=True)
        manifest.update({"names": "capitalized inside sentences >= 90% (1 document in 20, >= 10 times) -> <unk> "
                                  "unless sha256(name|key|sentence|position) mod 1000 >= name_unk * 1000",
                         "name_unk": name_unk, "name_count": len(names)})
    for source in selected:
        summary = build_source(source, args.out, args.workers, args.chat, names)
        manifest["sources"][source] = {"inputs": [{"path": p.name, "sha256": sha256(p)} for p in inputs[source]],
                                       "splits": summary}
    manifest["sources"]["masc"] = {"inputs": [{"path": sources.MASC_HELDOUT.name, "sha256": sha256(sources.MASC_HELDOUT)}],
                                   "splits": build_masc(args.out, vocabulary, lexicon)}
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
