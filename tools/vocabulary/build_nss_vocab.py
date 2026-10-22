#!/usr/bin/env python3
"""Select the neural-search-space (NSS) model vocabulary: the top N lexicon words.

Gboard's NSS model has a 30k-word vocabulary ("top words from Federated Counting")
while its lexicon holds 170k words; words outside the model vocabulary are scored
through the model's <UNK> probability times their unigram probability. We have no
federated counting, so this script ranks the shipped lexicon by a register-weighted
mix of public corpora and keeps the top N (default 30,000).

Candidates are the words of keyboard/langdata.bin that match [a-z']+ — only words
the trie can emit deserve a model slot. Each source is converted to a rate per
million running words, and a word's score is the weighted mean of its rates:

  frequency-words  hermitdave/FrequencyWords 2018 (subtitles; conversational)  0.45
  chat             optional plain-text messaging corpus (--chat)               0.20
  tatoeba          every Tatoeba English sentence                              0.20
  wikitext         WikiText-103 raw train split (formal)                       0.15

Weights of absent sources are dropped and the rest renormalised; the manifest
records the weights actually used. The default --mix geometric takes a weighted
geometric mean of half-count-smoothed rates, so a word one corpus overuses (Tatoeba's
"tom") cannot ride that spike up the ranking; --mix arithmetic pools the corpora. FrequencyWords strips apostrophes ("dont"), so
its counts are mapped back onto lexicon spellings: a stripped form shared by several
lexicon words ("ill" -> ill / i'll) is split in proportion to their counts in the
sources that keep apostrophes.

A word is eligible when it occurs at least --min-count times in at least
--min-sources sources, or at --conversational-ppm or more in FrequencyWords alone.
This drops single-source artifacts (subtitle character names, Wikipedia-only terms)
without starving common speech. FORCED words (contractions, number words, days,
months, chat forms) are always kept when they are in the lexicon. Profanity is kept:
suggestion-time safety penalties suppress it, and excluding it would only push it
to the weaker <UNK> path.

Outputs (all deterministic; ties break alphabetically):

  <out>/english-nss-vocab-<N>.tsv     id, word, score_ppm, sources (ids 0-3 special)
  <out>/english-nss-vocab-<N>.json    manifest: input hashes, weights, rules, coverage
  <out>/english-nss-vocab-<N>.review.tsv  cutoff band and rule-admitted words to inspect

The vocabulary file and the model's output layer are a pair: record the vocabulary
SHA-256 in every model export manifest.
"""

from __future__ import annotations

import argparse
import bz2
import hashlib
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))

from verify_language_data import Pack  # noqa: E402

REPO = TOOLS.parent
CACHE = TOOLS / ".cache"
DEFAULT_LANGDATA = REPO / "keyboard" / "langdata.bin"
DEFAULT_FREQUENCY_WORDS = CACHE / "en_full.txt"
DEFAULT_TATOEBA = TOOLS / "data" / "tatoeba-eng-2026-10-20.tsv.bz2"
DEFAULT_WIKITEXT = [CACHE / "wikitext-103-raw-train-00000-of-00002.parquet",
                    CACHE / "wikitext-103-raw-train-00001-of-00002.parquet"]
DEFAULT_HELDOUT = TOOLS / "data" / "english-masc-heldout-v1.json.bz2"
DEFAULT_OUT = TOOLS / "data" / "nss"

# Pinned in tools/build_language_data.py / ARTIFACTS.json; a mismatch is fatal.
EXPECTED_SHA256 = {
    "frequency-words": "7fea67ab954e2c01df6c608c9826e594cf36f8823b3243554f88245fb75dc506",
    "tatoeba": "bb3dcc28a8984a26dc466ee14eb53c4210b0dd9bb111b9d686d1efc83ecf091c",
    "wikitext-103-raw-train-00000-of-00002.parquet":
        "74da360f23826045b3e6ac6375411fdb15f003030aa74f2596ed08b857cb9212",
    "wikitext-103-raw-train-00001-of-00002.parquet":
        "ba090ac30dbf5461e8dcbdd1a1b8e6f3cf9c2c756d64f0c1220450acd514f720",
}
DEFAULT_WEIGHTS = {"frequency-words": 0.45, "chat": 0.20, "tatoeba": 0.20, "wikitext": 0.15}
SPECIALS = ["<pad>", "<unk>", "<bos>", "<eos>"]

LEXICON_WORD = re.compile(r"[a-z']+")
TOKEN = re.compile(r"[a-z]+(?:'[a-z]+)*")
WIKI_CONTRACTION = re.compile(r"(\w) '(s|re|ll|ve|m|d|t)\b")
WIKI_ESCAPES = ((" @-@ ", "-"), (" @,@ ", ","), (" @.@ ", "."))

_NUMBERS = ("zero one two three four five six seven eight nine ten eleven twelve thirteen "
            "fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty "
            "sixty seventy eighty ninety hundred thousand million billion first second third "
            "fourth fifth sixth seventh eighth ninth tenth")
_CALENDAR = ("monday tuesday wednesday thursday friday saturday sunday january february march "
             "april may june july august september october november december")
_CHAT = ("ok okay yeah yep yes no nope hey hi hello bye thanks thank thx pls plz please lol "
         "omg btw idk u ur ya gonna wanna gotta")
_CONTRACTIONS = ("i i'm i'll i've i'd you're you'll you've you'd he's he'll he'd she's she'll "
                 "she'd it's it'll we're we'll we've we'd they're they'll they've they'd "
                 "that's there's here's what's who's where's how's let's don't doesn't didn't "
                 "can't couldn't won't wouldn't shouldn't isn't aren't wasn't weren't haven't "
                 "hasn't hadn't mustn't")
FORCED = tuple(dict.fromkeys(" ".join((_CONTRACTIONS, _NUMBERS, _CALENDAR, _CHAT)).split()))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def display(path: Path) -> str:
    """Repository-relative path for manifests, so they do not embed a local checkout."""
    try:
        return str(path.resolve().relative_to(REPO))
    except ValueError:
        return path.name


def tokens(text: str) -> list[str]:
    text = text.lower().replace("’", "'").replace("‘", "'").replace("`", "'")
    return TOKEN.findall(text)


def load_lexicon(path: Path) -> tuple[set[str], int]:
    """Emittable [a-z'] lexicon words, plus how many other entries were skipped."""
    words, _ = Pack(path).vocabulary()
    decoded = [word.decode("utf-8") for word in words]
    lexicon = {word for word in decoded if LEXICON_WORD.fullmatch(word)}
    return lexicon, len(decoded) - len(lexicon)


def count_lines(lines, lexicon: set[str]) -> tuple[Counter, int]:
    """In-lexicon word counts and the total number of running word tokens."""
    counts, total = Counter(), 0
    for line in lines:
        found = tokens(line)
        total += len(found)
        counts.update(word for word in found if word in lexicon)
    return counts, total


def tatoeba_lines(path: Path):
    with bz2.open(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            fields = line.rstrip("\n").split("\t", 2)
            if len(fields) == 3 and fields[1] == "eng":
                yield fields[2]


def wikitext_lines(paths):
    import pyarrow.parquet as pq  # build-time only dependency
    for path in paths:
        parquet = pq.ParquetFile(path)
        for group in range(parquet.num_row_groups):
            for text in parquet.read_row_group(group, columns=["text"]).column("text").to_pylist():
                text = text.strip()
                if not text or text.startswith("="):
                    continue
                for old, new in WIKI_ESCAPES:
                    text = text.replace(old, new)
                yield WIKI_CONTRACTION.sub(r"\1'\2", text)


def text_lines(paths):
    for path in paths:
        opener = bz2.open if path.suffix == ".bz2" else open
        with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
            yield from handle


def read_frequency_list(path: Path) -> list[tuple[str, int]]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) == 2 and parts[1].isdigit():
                rows.append((parts[0].lower(), int(parts[1])))
    return rows


def map_frequency_words(rows, lexicon: set[str], evidence: Counter) -> tuple[Counter, int]:
    """Map apostrophe-stripped FrequencyWords counts onto lexicon spellings.

    `evidence` holds counts from sources that keep apostrophes; it decides how a
    shared stripped form ("ill" for ill / i'll) is divided. Without evidence the
    count is split evenly.
    """
    by_stripped: dict[str, list[str]] = defaultdict(list)
    for word in sorted(lexicon):
        by_stripped[word.replace("'", "")].append(word)
    counts, total = Counter(), 0
    for token, count in rows:
        if not TOKEN.fullmatch(token):
            continue
        total += count
        targets = by_stripped.get(token.replace("'", ""))
        if not targets:
            continue
        if len(targets) == 1:
            counts[targets[0]] += count
            continue
        shares = [evidence[target] + 0.5 for target in targets]
        whole = sum(shares)
        for target, share in zip(targets, shares):
            counts[target] += count * share / whole
    return counts, total


def score_words(sources: dict[str, tuple[Counter, int]], weights: dict[str, float],
                lexicon: set[str], mix: str = "geometric") -> tuple[dict[str, float], dict[str, float]]:
    """Per-million rate of each word under the weighted source mix.

    "arithmetic" is the rate in the pooled, re-weighted corpus. "geometric" is the
    weighted geometric mean of rates smoothed by half a count per source, so a word
    only one corpus overuses (Tatoeba's "tom") cannot ride that spike to the top.
    """
    used = {name: weights[name] for name in sources}
    whole = sum(used.values())
    used = {name: weight / whole for name, weight in used.items()}
    scores = {}
    for word in lexicon:
        if mix == "arithmetic":
            scores[word] = sum(used[name] * counts[word] * 1e6 / max(total, 1)
                               for name, (counts, total) in sources.items())
        else:
            scores[word] = math.exp(sum(used[name] * math.log((counts[word] + 0.5) * 1e6 / max(total, 1))
                                        for name, (counts, total) in sources.items()))
    return scores, used


def select(scores, sources, lexicon, size: int, min_count: float, min_sources: int,
           conversational_ppm: float, include=()) -> tuple[list[tuple[str, str]], Counter]:
    """Return [(word, admission rule)] in rank order and rule tallies."""
    conversational = sources.get("frequency-words")
    forced = {word for word in (*FORCED, *include) if word in lexicon}
    ranked = []
    for word in lexicon:
        if word in forced:
            ranked.append((word, "forced"))
            continue
        present = sum(1 for counts, _ in sources.values() if counts[word] >= min_count)
        if present >= min_sources:
            ranked.append((word, "multi-source"))
        elif conversational and conversational[0][word] * 1e6 / max(conversational[1], 1) \
                >= conversational_ppm:
            ranked.append((word, "conversational"))
    # Forced words always fit; every other slot goes to the best-scoring eligible word.
    forced_rows = [(word, rule) for word, rule in ranked if rule == "forced"]
    if len(forced_rows) > size:
        raise ValueError(f"{len(forced_rows)} forced words exceed the vocabulary size {size}")
    others = sorted((row for row in ranked if row[1] != "forced"),
                    key=lambda row: (-scores[row[0]], row[0]))
    chosen = forced_rows + others[:size - len(forced_rows)]
    chosen.sort(key=lambda row: (-scores[row[0]], row[0]))
    return chosen, Counter(rule for _, rule in chosen)


def heldout_coverage(path: Path, vocabulary: set[str], lexicon: set[str]) -> dict:
    data = json.load(bz2.open(path, "rt", encoding="utf-8"))
    tallies = defaultdict(lambda: [0, 0, 0])  # running, in lexicon, in vocabulary
    for sentence in data["sentences"]:
        parts = sentence.get("document", "").split("/")
        family = parts[1] if len(parts) > 2 else "all"
        for token in sentence["tokens"]:
            if token is None:
                continue
            for key in ("all", family):
                tally = tallies[key]
                tally[0] += 1
                tally[1] += token in lexicon
                tally[2] += token in vocabulary
    return {key: {"tokens": running, "lexicon_coverage": round(in_lexicon / running, 5),
                  "vocabulary_coverage": round(in_vocab / running, 5),
                  "vocabulary_coverage_of_lexicon_tokens": round(in_vocab / max(in_lexicon, 1), 5)}
            for key, (running, in_lexicon, in_vocab) in sorted(tallies.items())}


def source_coverage(sources, vocabulary: set[str]) -> dict:
    report = {}
    for name, (counts, total) in sources.items():
        in_lexicon = sum(counts.values())
        in_vocab = sum(count for word, count in counts.items() if word in vocabulary)
        report[name] = {"running_tokens": total,
                        "vocabulary_coverage": round(in_vocab / max(total, 1), 5),
                        "vocabulary_coverage_of_lexicon_tokens": round(in_vocab / max(in_lexicon, 1), 5)}
    return report


def verify(path: Path, key: str, skip: bool) -> str:
    actual = sha256(path)
    expected = EXPECTED_SHA256.get(key)
    if expected and actual != expected and not skip:
        sys.exit(f"checksum mismatch for {path}: expected {expected}, got {actual}")
    return actual


def parse_weights(text: str | None) -> dict[str, float]:
    weights = dict(DEFAULT_WEIGHTS)
    for item in filter(None, (text or "").split(",")):
        name, _, value = item.partition("=")
        if name not in weights:
            raise SystemExit(f"unknown source in --weights: {name}")
        weights[name] = float(value)
    return weights


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--size", type=int, default=30_000)
    parser.add_argument("--langdata", type=Path, default=DEFAULT_LANGDATA)
    parser.add_argument("--frequency-words", type=Path, default=DEFAULT_FREQUENCY_WORDS)
    parser.add_argument("--tatoeba", type=Path, default=DEFAULT_TATOEBA)
    parser.add_argument("--wikitext", type=Path, nargs="*", default=DEFAULT_WIKITEXT)
    parser.add_argument("--no-wikitext", action="store_true", help="skip the slowest source")
    parser.add_argument("--chat", type=Path, nargs="*", default=[],
                        help="plain-text messaging corpus files (.txt or .bz2)")
    parser.add_argument("--heldout", type=Path, default=DEFAULT_HELDOUT)
    parser.add_argument("--weights", help="e.g. frequency-words=0.5,tatoeba=0.3")
    parser.add_argument("--mix", choices=("geometric", "arithmetic"), default="geometric")
    parser.add_argument("--include", type=Path, nargs="*", default=[],
                        help="curated words always kept when in the lexicon, one per line "
                             "(e.g. post-2018 terms the pinned corpora predate)")
    parser.add_argument("--min-count", type=float, default=3)
    parser.add_argument("--min-sources", type=int, default=2)
    parser.add_argument("--conversational-ppm", type=float, default=20.0)
    parser.add_argument("--review-band", type=int, default=200)
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--skip-hash-check", action="store_true",
                        help="research inputs only; the manifest still records actual hashes")
    return parser.parse_args(argv)


def main(argv=None) -> None:
    args = parse_args(argv)
    weights = parse_weights(args.weights)
    lexicon, skipped = load_lexicon(args.langdata)
    inputs = {"langdata": {"path": display(args.langdata), "sha256": sha256(args.langdata)}}
    print(f"lexicon: {len(lexicon):,} emittable words ({skipped:,} non-[a-z'] entries skipped)",
          flush=True)

    sources: dict[str, tuple[Counter, int]] = {}
    if args.tatoeba.exists():
        inputs["tatoeba"] = {"path": display(args.tatoeba),
                             "sha256": verify(args.tatoeba, "tatoeba", args.skip_hash_check)}
        sources["tatoeba"] = count_lines(tatoeba_lines(args.tatoeba), lexicon)
        print(f"tatoeba: {sources['tatoeba'][1]:,} tokens", flush=True)
    wikitext = [] if args.no_wikitext else [path for path in args.wikitext if path.exists()]
    if wikitext:
        inputs["wikitext"] = [{"path": display(path),
                               "sha256": verify(path, path.name, args.skip_hash_check)}
                              for path in wikitext]
        sources["wikitext"] = count_lines(wikitext_lines(wikitext), lexicon)
        print(f"wikitext: {sources['wikitext'][1]:,} tokens", flush=True)
    if args.chat:
        inputs["chat"] = [{"path": display(path), "sha256": sha256(path)} for path in args.chat]
        sources["chat"] = count_lines(text_lines(args.chat), lexicon)
        print(f"chat: {sources['chat'][1]:,} tokens", flush=True)
    if args.frequency_words.exists():
        inputs["frequency-words"] = {
            "path": display(args.frequency_words),
            "sha256": verify(args.frequency_words, "frequency-words", args.skip_hash_check)}
        evidence = Counter()
        for counts, _ in sources.values():
            evidence.update(counts)
        sources["frequency-words"] = map_frequency_words(
            read_frequency_list(args.frequency_words), lexicon, evidence)
        print(f"frequency-words: {sources['frequency-words'][1]:,} tokens", flush=True)
    if not sources:
        sys.exit("no corpus sources found; see --help for the expected inputs")
    if len(sources) < args.min_sources:
        sys.exit(f"{len(sources)} sources available but --min-sources is {args.min_sources}")

    include = []
    for path in args.include:
        inputs.setdefault("include", []).append({"path": display(path), "sha256": sha256(path)})
        include += [line.strip().lower() for line in path.read_text(encoding="utf-8").splitlines()
                    if line.strip() and not line.startswith("#")]
    scores, used_weights = score_words(sources, weights, lexicon, args.mix)
    chosen, rules = select(scores, sources, lexicon, args.size, args.min_count,
                           args.min_sources, args.conversational_ppm, include)
    if len(chosen) < args.size:
        print(f"warning: only {len(chosen):,} words are eligible for {args.size:,} slots",
              file=sys.stderr)
    vocabulary = {word for word, _ in chosen}

    args.out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"english-nss-vocab-{args.size // 1000}k" if args.size % 1000 == 0 \
        else f"english-nss-vocab-{args.size}"
    vocab_path = args.out_dir / f"{stem}.tsv"
    lines = ["id\tword\tscore_ppm\tsources"]
    lines += [f"{index}\t{token}\t\t" for index, token in enumerate(SPECIALS)]
    for index, (word, _) in enumerate(chosen, start=len(SPECIALS)):
        present = ",".join(name for name, (counts, _) in sorted(sources.items()) if counts[word] > 0)
        lines.append(f"{index}\t{word}\t{scores[word]:.4f}\t{present}")
    vocab_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    review_path = args.out_dir / f"{stem}.review.tsv"
    # Rank the excluded words the same way the cutoff did, eligible ones first, so
    # "cutoff-outside" shows the real runners-up; single-source words follow as a
    # separate section for curation through --include.
    eligible = {word for word in lexicon
                if sum(1 for counts, _ in sources.values() if counts[word] >= args.min_count)
                >= args.min_sources}
    eligible_rank = sorted((word for word in eligible if word not in vocabulary),
                           key=lambda word: (-scores[word], word))
    rejected_rank = sorted((word for word in lexicon - eligible - vocabulary),
                           key=lambda word: (-scores[word], word))
    review = ["section\trank\tword\tscore_ppm\trule"]
    band = args.review_band
    for rank, (word, rule) in enumerate(chosen, start=1):
        if rank > len(chosen) - band or rule != "multi-source":
            section = "cutoff-inside" if rank > len(chosen) - band else f"admitted-{rule}"
            review.append(f"{section}\t{rank}\t{word}\t{scores[word]:.4f}\t{rule}")
    for offset, word in enumerate(eligible_rank[:band], start=1):
        review.append(f"cutoff-outside\t{len(chosen) + offset}\t{word}\t{scores[word]:.4f}\t-")
    for word in rejected_rank[:band]:
        review.append(f"rejected-single-source\t-\t{word}\t{scores[word]:.4f}\t-")
    review_path.write_text("\n".join(review) + "\n", encoding="utf-8")

    manifest = {
        "schema_version": 1,
        "vocabulary": {"path": vocab_path.name, "sha256": sha256(vocab_path),
                       "words": len(chosen), "specials": SPECIALS,
                       "model_vocab_size": len(chosen) + len(SPECIALS)},
        "inputs": inputs,
        "lexicon": {"emittable_words": len(lexicon), "skipped_non_word_entries": skipped},
        "weights_used": {name: round(weight, 6) for name, weight in sorted(used_weights.items())},
        "mix": args.mix,
        "rules": {"min_count": args.min_count, "min_sources": args.min_sources,
                  "conversational_ppm": args.conversational_ppm,
                  "forced_requested": len(FORCED) + len(include),
                  "forced_missing_from_lexicon": sorted(set(FORCED) - lexicon),
                  "include_missing_from_lexicon": sorted(set(include) - lexicon)},
        "admitted_by_rule": dict(sorted(rules.items())),
        "source_coverage": source_coverage(sources, vocabulary),
        "oov_policy": "words outside the vocabulary score P(<unk>|context) * unigram probability",
    }
    if args.heldout.exists():
        manifest["heldout"] = {"path": display(args.heldout), "sha256": sha256(args.heldout),
                               "coverage": heldout_coverage(args.heldout, vocabulary, lexicon)}
    manifest_path = args.out_dir / f"{stem}.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"wrote {vocab_path} ({len(chosen):,} words + {len(SPECIALS)} specials)")
    print(f"admitted: {dict(sorted(rules.items()))}; weights: {manifest['weights_used']}")
    for name, report in manifest["source_coverage"].items():
        print(f"  {name}: {report['vocabulary_coverage']:.2%} of running tokens")
    if "heldout" in manifest:
        overall = manifest["heldout"]["coverage"]["all"]
        print(f"  held-out MASC: {overall['vocabulary_coverage']:.2%} of tokens "
              f"({overall['vocabulary_coverage_of_lexicon_tokens']:.2%} of in-lexicon tokens)")


if __name__ == "__main__":
    main()
