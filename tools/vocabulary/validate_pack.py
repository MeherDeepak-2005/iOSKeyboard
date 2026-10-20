#!/usr/bin/env python3
"""Compare English packs by surface form, not remapped numeric word IDs."""
import argparse
import bz2
from collections import Counter
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'tools/evaluation'))
from verify_language_data import Pack
from audit_english_coverage import PROBES


def vocabulary(pack):
    words, frequencies = pack.vocabulary()
    words = [w.decode('utf-8') for w in words]
    if len(set(words)) != len(words):
        raise ValueError('duplicate vocabulary forms')
    if list(frequencies) != sorted(frequencies, reverse=True):
        raise ValueError('vocabulary is not frequency ordered')
    return words, dict(zip(words, frequencies))


def ngrams(pack, words, width):
    result = {}
    groups = pack.bigrams() if width == 2 else pack.trigrams()
    for key, (total, entries) in groups.items():
        context = (key,) if width == 2 else pack.context_pair(key)
        if any(w >= len(words) for w in context) or any(w >= len(words) for w, _ in entries):
            raise ValueError('out-of-range word ID')
        if total < sum(c for _, c in entries):
            raise ValueError('probability denominator below retained counts')
        if len(set(w for w, _ in entries)) != len(entries):
            raise ValueError('duplicate continuation')
        for successor, count in entries:
            result[tuple(words[w] for w in context) + (words[successor],)] = count
    return result


def validate(baseline, candidate, output):
    b, n = Pack(baseline), Pack(candidate)
    bw, bf = vocabulary(b)
    nw, nf = vocabulary(n)
    if n.version not in (5, 6) or len(n.data) > (20_000_000 if n.version == 6 else 11_000_000) or n.words > (0x7fffffff if n.version == 6 else 65534):
        raise ValueError('release format/size/word-ID guard failed')
    if any(nf.get(word) != frequency for word, frequency in bf.items()):
        raise ValueError('baseline word or frequency changed')
    def distributions(pack, words, width):
        groups = pack.bigrams() if width == 2 else pack.trigrams()
        return {tuple(words[w] for w in ((key,) if width == 2 else pack.context_pair(key))):
                (total, tuple((words[w], count) for w, count in entries))
                for key, (total, entries) in groups.items()}
    exact_contexts = True
    counts = {}
    for width in (2, 3):
        old, new = ngrams(b, bw, width), ngrams(n, nw, width)
        if any(new.get(key, 0) < count for key, count in old.items()):
            raise ValueError('baseline n-gram record/count was lost')
        if distributions(b, bw, width) != distributions(n, nw, width):
            exact_contexts = False
        counts[str(width)] = {'baseline': len(old), 'expanded': len(new), 'additional': len(new)-len(old)}
    starters_preserved = tuple((bw[w], c) for w, c in b.sentence_starters()) == tuple((nw[w], c) for w, c in n.sentence_starters())
    if not starters_preserved or (n.version == 6 and not exact_contexts):
        raise ValueError('CoreV4 migration changed existing context distributions or starters')
    categories = {}
    for category, text in PROBES.items():
        keys = {w.lower().replace('’', "'") for w in text.split()}
        categories[category] = {'tested': len(keys), 'baseline_present': len(keys & bf.keys()),
            'expanded_present': len(keys & nf.keys()), 'remaining_missing': sorted(keys - nf.keys())}
    keys = {w.lower().replace('’', "'") for text in PROBES.values() for w in text.split()}
    record = json.loads((ROOT/'tools/data/english-expansion-v1.manifest.json').read_text())['artifacts']['heldout']
    payload = (ROOT/record['path']).read_bytes()
    if hashlib.sha256(payload).hexdigest() != record['sha256']:
        raise ValueError('held-out checksum mismatch')
    heldout = json.loads(bz2.decompress(payload))
    tokens = Counter(token for row in heldout['sentences'] for token in row['tokens'] if token is not None)
    heldout_counts = {}
    for name, vocab in [('baseline', bf), ('expanded', nf)]:
        known = sum(count for token, count in tokens.items() if token in vocab)
        heldout_counts[name] = {'supported_tokens': sum(tokens.values()), 'known_tokens': known,
            'token_coverage_pct': 100*known/sum(tokens.values()),
            'unsupported_spans': sum(token is None for row in heldout['sentences'] for token in row['tokens'])}
    result = {'schema_version': 1, 'all_baseline_words_and_frequencies_preserved': True,
        'context_distributions_including_totals_exactly_preserved': exact_contexts,
        'sentence_starters_exactly_preserved': starters_preserved,
        'all_baseline_ngram_counts_retained_or_increased': True,
        'baseline': {'words': b.words, 'bytes': len(b.data), 'sha256': hashlib.sha256(b.data).hexdigest()},
        'expanded': {'words': n.words, 'bytes': len(n.data), 'sha256': hashlib.sha256(n.data).hexdigest(),
            'trie_nodes': n.trie_nodes, 'bigram_contexts': n.bi_contexts, 'bigram_entries': n.bi_entries,
            'trigram_contexts': n.tri_contexts, 'trigram_entries': n.tri_entries, 'sentence_starters': n.starters},
        'ngram_entries': counts,
        'diagnostic_probes': {'unique_keys': len(keys), 'baseline_present': len(keys & bf.keys()),
            'expanded_present': len(keys & nf.keys()), 'categories': categories,
            'limitation': 'Targeted admission-influenced probes measure membership, not independent decoder recall.'},
        'masc_heldout': {'sentences': len(heldout['sentences']), 'coverage': heldout_counts,
            'limitation': 'Document-family held-out split; author isolation unavailable. Supported lexical tokens only; not decoder recall.'}}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print(json.dumps({key: result[key] for key in ['baseline', 'expanded', 'masc_heldout']}, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'docs/english-vocabulary/expansion-validation.json')
    args = parser.parse_args()
    validate(args.baseline, args.candidate, args.output)
