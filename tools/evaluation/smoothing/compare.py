#!/usr/bin/env python3
"""Frozen-pack paired WB/MKN comparison; offline proxies, not device replay.

python3 tools/evaluation/smoothing/compare.py
"""
import argparse
import bz2
from collections import defaultdict
from functools import lru_cache
import gzip
import hashlib
import heapq
import json
import math
from pathlib import Path, PurePosixPath
import random
import re
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/lm'))
from eval_harness import LangData, ModifiedKneserNey, corrupt, cost_budget

NAMES = ('witten_bell', 'modified_kneser_ney')
SEED = 20261019


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Models:
    def __init__(self, ld):
        self.ld = ld
        start = time.perf_counter()
        self.kn = ModifiedKneserNey(ld)
        self.kn_init_seconds = time.perf_counter() - start
        self.wb_total = sum(ld.freqs) + ld.W
        self.uni_top = {
            'witten_bell': heapq.nlargest(3, range(ld.W), key=lambda w: (ld.freqs[w], ld.words[w])),
            'modified_kneser_ney': heapq.nlargest(3, range(ld.W), key=lambda w: (self.kn.unigrams.get(w, .5), ld.words[w]))}

    @lru_cache(maxsize=100000)
    def tables(self, context):
        previous = self.ld.ids.get(context[-1]) if context else None
        first = self.ld.ids.get(context[-2]) if len(context) > 1 else None
        bi = self.ld.bigrams(previous) if previous is not None else None
        tri = self.ld.trigrams(first, previous) if first is not None and previous is not None else None
        def wb(hit):
            if not hit or hit[0] <= 0 or not hit[1]:
                return None
            total, entries = hit
            weight = total / (total + len(entries)) * total / (total + 8.)
            return total, weight, dict(entries)
        return (wb(bi), wb(tri), self.kn.bigrams.get(previous),
                self.kn.prepare(tri[1], self.kn.tri_discounts) if tri else None)

    def lp(self, name, wid, context):
        bi, tri, knbi, kntri = self.tables(tuple(context[-2:]))
        if name == 'witten_bell':
            p = (self.ld.freqs[wid] + 1 if wid is not None else .5) / self.wb_total
            for row in (bi, tri):
                if row:
                    total, weight, counts = row
                    p = weight * counts.get(wid, 0) / total + (1 - weight) * p
        else:
            p = self.kn.unigrams.get(wid, .5) / self.kn.total
            for row in (knbi, kntri):
                p = self.kn.interpolate(row, wid, p)
        return math.log(max(p, float.fromhex('0x0.0000000000001p-1022')))

    @lru_cache(maxsize=100000)
    def top3(self, name, context):
        tables = self.tables(context)
        rows = tables[:2] if name == 'witten_bell' else tables[2:]
        # Outside the observed successor sets, order is monotonic in unigram
        # probability. Their top three plus every successor give exact full-vocab top3.
        pool = set(self.uni_top[name])
        for row in rows:
            if row:
                pool.update(row[2])
        return tuple(heapq.nlargest(3, pool, key=lambda w: (self.lp(name, w, context), self.ld.words[w])))


def family(document):
    p = PurePosixPath(document)
    return str(p.parent / re.sub(r'(?:[-_]\d+)+$', '', p.stem))


def interval(groups, metric, trials=5000):
    # Paired document-family bootstrap; sentence/token samples are not independent.
    rows = list(groups.values())
    rng = random.Random(SEED)
    values = []
    for _ in range(trials):
        chosen = rng.choices(rows, k=len(rows))
        count = sum(r['n'] for r in chosen)
        values.append(sum(r[metric] for r in chosen) / count)
    values.sort()
    return [values[int(.025 * trials)], values[int(.975 * trials)]]


def summarize(events, metrics):
    groups = defaultdict(lambda: defaultdict(float))
    totals = {name: defaultdict(float) for name in NAMES}
    for event in events:
        group = groups[event['family']]
        group['n'] += 1
        for metric in metrics:
            for name in NAMES:
                totals[name][metric] += event[name][metric]
            group[metric] += event[NAMES[1]][metric] - event[NAMES[0]][metric]
    return {'cases': len(events), 'document_families': len(groups),
            'models': {name: {m: totals[name][m] / len(events) for m in metrics} for name in NAMES},
            'mkn_minus_wb': {m: {'difference': (totals[NAMES[1]][m] - totals[NAMES[0]][m]) / len(events),
                                  'paired_document_bootstrap_95_ci': interval(groups, m)} for m in metrics}}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, default=ROOT/'tools/evaluation/results/smoothing-2026-10-19')
    ap.add_argument('--typo-cases', type=int, default=3000)
    args = ap.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    pack = ROOT/'keyboard/langdata.bin'
    heldout = ROOT/'tools/data/english-masc-heldout-v1.json.bz2'
    manifest = json.loads((ROOT/'tools/data/english-expansion-v1.manifest.json').read_text())
    assert sha(heldout) == manifest['artifacts']['heldout']['sha256']
    dataset = json.loads(bz2.decompress(heldout.read_bytes()))
    assert all(int(hashlib.sha256(family(s['document']).encode()).hexdigest()[:8], 16) % 5 == 0
               for s in dataset['sentences'])
    ld = LangData(pack)
    models = Models(ld)
    events, eligible = [], []
    print('Loaded verified held-out data and both models', flush=True)
    for sentence in dataset['sentences']:
        context = []
        for word in sentence['tokens']:
            if word is None:
                context = []
                continue
            if context and word in ld.ids:
                ctx = tuple(context[-2:])
                event = {'family': family(sentence['document']), 'gold': word, 'context': ctx}
                for name in NAMES:
                    top = models.top3(name, ctx)
                    event[name] = {'top1': int(ld.ids[word] == top[0]),
                                   'top3': int(ld.ids[word] in top),
                                   'negative_log_score': -models.lp(name, ld.ids[word], ctx)}
                events.append(event)
                if len(word) >= 4 and word.isascii() and word.isalpha():
                    eligible.append((event['family'], word, ctx))
            context.append(word)
    report = {'schema_version': 1, 'seed': SEED,
              'pack_sha256': sha(pack), 'heldout_sha256': sha(heldout),
              'script_sha256': sha(Path(__file__)),
              'method': 'Exact full-vocabulary LM top-k; fixed native unfunded fuzzy candidates for synthetic typo/clean-input proxy.',
              'limits': [dataset['limitation'],
                         'CoreV4 source provenance cannot establish isolation from all vocabulary-frequency sources.',
                         'Only in-vocabulary targets after at least one supported context token; unknown spans reset context.',
                         'Synthetic errors never alter the first letter; no real-user labels; no complete engine policy, personalization, context injection, multiword search or device performance.',
                         'Negative log scores use deployed unknown floors; not normalized-vocabulary perplexity.',
                         'Native C++ search is identical for both; fixed 32-row channel/frequency cap, weights 1.0/0.3 and margins 3.0 OOV, 5.0 known.'],
              'next_word_lm_proxy': summarize(events, ['top1', 'top3', 'negative_log_score']),
              'python_mkn_statistics_init_seconds': models.kn_init_seconds}
    print(json.dumps(report['next_word_lm_proxy'], indent=2), flush=True)
    rng = random.Random(SEED)
    rng.shuffle(eligible)
    cases = []
    for fam, word, ctx in eligible:
        typo = corrupt(word, rng, edits=1)
        if typo != word and typo.isalpha() and typo not in ld.ids:
            cases.append((fam, typo, word, ctx))
        if len(cases) >= args.typo_cases:
            break
    clean = [(fam, word, word, ctx) for fam, word, ctx in eligible[:args.typo_cases]]
    with tempfile.TemporaryDirectory(prefix='kb-smoothing-') as tmp:
        executable = Path(tmp)/'candidates'
        subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O3', '-I'+str(ROOT/'native/DecoderCore/include'),
                        str(Path(__file__).with_name('candidates.cpp')),
                        *[str(ROOT/f'native/DecoderCore/src/{s}.cpp') for s in ('PackedLexicon', 'SpatialModel', 'IncrementalSearch')],
                        '-o', str(executable)], check=True)
        with subprocess.Popen([str(executable), str(pack)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as process:
            results = []
            for index, (fam, typed, gold, ctx) in enumerate(cases + clean):
                process.stdin.write(f'{typed} {cost_budget(len(typed))}\n'); process.stdin.flush()
                fields = process.stdout.readline().rstrip('\n').split('\t')
                count = int(fields[0])
                assert len(fields) == 1 + 3 * count
                pool = [(fields[i], float(fields[i+1]), float(fields[i+2])) for i in range(1, len(fields), 3)]
                pool.sort(key=lambda r: (-r[1] + .3 * r[2], r[0]), reverse=True)
                pool = pool[:31]
                if all(row[0] != typed for row in pool):
                    wid = ld.ids.get(typed)
                    pool.append((typed, 0., math.log1p(ld.freqs[wid]) if wid is not None else 0.))
                event = {'family': fam, 'typed': typed, 'gold': gold, 'context': ctx,
                         'slice': 'typo' if typed != gold else 'clean',
                         'oracle': int(any(r[0] == gold for r in pool))}
                for name in NAMES:
                    scored = sorted([(-cost + models.lp(name, ld.ids.get(w), ctx) + .3 * lf, w, cost)
                                     for w, cost, lf in pool], reverse=True)
                    top = [r[1] for r in scored[:3]]
                    typed_score = next(r[0] for r in scored if r[1] == typed)
                    alternatives = [r for r in scored if r[1] != typed and (typed not in ld.ids or r[2] <= 1.6)]
                    threshold = 5. if typed in ld.ids else 3.
                    chosen = alternatives[0][1] if alternatives and alternatives[0][0] - typed_score > threshold else typed
                    event[name] = {'top1': int(top[0] == gold), 'top3': int(gold in top),
                                   'committed_correct': int(chosen == gold),
                                   'incorrect_result': int(chosen != gold),
                                   'wrong_commit': int(chosen != typed and chosen != gold),
                                   'changed': int(chosen != typed), 'choice': chosen, 'top': top}
                results.append(event)
                if (index+1) % 1000 == 0:
                    print(f'Scored {index+1}/{len(cases+clean)} shared candidate batches', flush=True)
            process.stdin.close()
            assert process.wait() == 0
    for label in ('typo', 'clean'):
        rows = [r for r in results if r['slice'] == label]
        report[label+'_proxy'] = summarize(rows, ['top1', 'top3', 'committed_correct', 'incorrect_result', 'wrong_commit', 'changed'])
        report[label+'_proxy']['shared_candidate_oracle_recall'] = statistics.mean(r['oracle'] for r in rows)
    report['changed_outcome_examples'] = [r for r in results if r[NAMES[0]]['choice'] != r[NAMES[1]]['choice']][:30]
    with gzip.open(args.output/'events.jsonl.gz', 'wt') as handle:
        for row in events + results:
            handle.write(json.dumps(row)+'\n')
    (args.output/'summary.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: v for k, v in report.items() if k.endswith('_proxy')}, indent=2), flush=True)
    print(args.output/'summary.json', flush=True)


if __name__ == '__main__':
    main()
