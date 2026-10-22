#!/usr/bin/env python3
"""Build an optional KBLM v6 pack from one CoreV4 English context variant.

The CoreV4 vocabulary union remains in the current active pack. This command
replaces its frequency/context evidence with one variant's extracted model and
keeps the current iOS sentence starters as an explicit product fallback.
"""
from __future__ import annotations

import argparse
import bz2
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import build_language_data as builder
from verify_language_data import Pack

SOURCE = ROOT / 'tools/data/corev4/english/contexts'


def load_variant(label):
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    record = next((x for x in manifest['variants'] if x['variant'] == label), None)
    if record is None: raise ValueError(f'unknown CoreV4 variant: {label}')
    path = SOURCE.parent / record['path']
    if hashlib.sha256(path.read_bytes()).hexdigest() != record['sha256']:
        raise ValueError('CoreV4 context snapshot checksum mismatch')
    with bz2.open(path, 'rt', encoding='utf-8') as stream:
        data = json.load(stream)
    if data['schema_version'] != 1 or data['variant'] != label or len(data['words']) != record['words']:
        raise ValueError('CoreV4 context manifest mismatch')
    if len(data['unigram']) != len(data['words']) or len(set(data['words'])) != len(data['words']):
        raise ValueError('CoreV4 dictionary/count mismatch')
    return data


def build(source_pack, data, output, mode='replace'):
    original = Pack(source_pack)
    if original.version != 6:
        raise ValueError('expected the complete CoreV4 vocabulary union in a v6 pack')
    original_words, original_weights = original.vocabulary()
    original_words = [x.decode('utf-8') for x in original_words]
    original_ids = {word: i for i, word in enumerate(original_words)}
    weights = {word: original_weights[i] if mode == 'merge' else 1
               for i, word in enumerate(original_words)}
    missing_words = []
    for word, count in zip(data['words'], data['unigram']):
        if word in weights:
            if mode == 'replace': weights[word] = count
        else:
            missing_words.append(word)
    if set(missing_words) != set(builder.EXCLUDE) & set(data['words']):
        raise ValueError(f'unexpected CoreV4 words missing from active vocabulary: {missing_words[:8]}')
    vocab = (list(zip(original_words, original_weights)) if mode == 'merge'
             else sorted(weights.items(), key=lambda item: (-item[1], item[0])))
    ids = {word: i for i, (word, _) in enumerate(vocab)}

    def mapped(local):
        if not 1 <= local <= len(data['words']): return None
        return ids.get(data['words'][local - 1])

    bi = defaultdict(Counter)
    tri = defaultdict(Counter)
    totals = {'bigrams': {}, 'trigrams': {}}
    if mode == 'merge':
        for key, (total, rows) in original.bigrams().items():
            bi[key].update(dict(rows))
            totals['bigrams'][key] = total
        for key, (total, rows) in original.trigrams().items():
            tri[key].update(dict(rows))
            totals['trigrams'][key] = total
    excluded = Counter()
    for app, first, second, _, count in data['bigram']:
        a, b = mapped(first), mapped(second)
        if app != 1 or a is None or b is None:
            excluded['bigram'] += 1
        else:
            bi[a][b] += count
            totals['bigrams'][a] = totals['bigrams'].get(a, 0) + count
    for app, first, second, third, count in data['trigram']:
        a, b, c = mapped(first), mapped(second), mapped(third)
        if app != 1 or a is None or b is None or c is None:
            excluded['trigram'] += 1
        else:
            tri[(a, b)][c] += count
            totals['trigrams'][(a, b)] = totals['trigrams'].get((a, b), 0) + count
    bi = {key: sorted(values.items(), key=lambda row: (-row[1], row[0])) for key, values in bi.items()}
    tri = {key: sorted(values.items(), key=lambda row: (-row[1], row[0])) for key, values in tri.items()}

    # These are the current iOS product's explicit cold-start priors, retained
    # separately from the CoreV4 n-gram evidence for fair keyboard use.
    starters = [(ids[original_words[word]], count)
                for word, count in original.sentence_starters()]
    builder.write_bin(vocab, bi, tri, starters, output=output, version=6,
                      context_totals=totals)

    result = Pack(output)
    actual_words, actual_weights = result.vocabulary()
    if actual_words != tuple(w.encode() for w, _ in vocab) or actual_weights != tuple(c for _, c in vocab):
        raise ValueError('unigram pack parity failed')
    actual_bi, actual_tri = result.bigrams(), result.trigrams()
    if len(actual_bi) != len(bi) or sum(len(rows[1]) for rows in actual_bi.values()) != sum(map(len, bi.values())):
        raise ValueError('bigram pack parity failed')
    if len(actual_tri) != len(tri) or sum(len(rows[1]) for rows in actual_tri.values()) != sum(map(len, tri.values())):
        raise ValueError('trigram pack parity failed')
    for key, rows in bi.items():
        total, actual = actual_bi[key]
        if total != totals['bigrams'][key] or actual != tuple(rows):
            raise ValueError('bigram record parity failed')
    for key, rows in tri.items():
        total, actual = actual_tri[key]
        if total != totals['trigrams'][key] or actual != tuple(rows):
            raise ValueError('trigram record parity failed')
    report = dict(variant=data['variant'], mode=mode, pack=str(output), sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
                  bytes=output.stat().st_size, forms=len(vocab), bigrams=sum(map(len, bi.values())),
                  trigrams=sum(map(len, tri.values())), excluded_records=dict(excluded),
                  legacy_next_next_preserved_offline=len(data['next_next']),
                  original_ios_sentence_starters=len(starters), parity='PASS')
    output.with_suffix('.report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', default='en-IN-95359-da2687ef')
    parser.add_argument('--source-pack', type=Path, default=ROOT / 'keyboard/langdata.bin')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=('replace', 'merge'), default='replace')
    args = parser.parse_args()
    if not args.output.parent.is_dir(): parser.error('output directory does not exist')
    if args.output.resolve() == args.source_pack.resolve():
        parser.error('optional model output must differ from active pack')
    print(json.dumps(build(args.source_pack, load_variant(args.variant), args.output, args.mode), indent=2))


if __name__ == '__main__': main()
