#!/usr/bin/env python3
"""Alternating desktop latency replay after compare_paper.py's full quality run.

python3 tools/nss/latency_paper.py --out /tmp/nss-latency [--chat MODEL.nsslm]

Arms (decoder, model):
  before       BASELINE, the decoder before the published graph   baseline-step8000.nsslm
  paper        PAPER, the published graph as committed             keyboard/nss-english.nsslm
  after-paper  the working tree with KB_NSS_PAPER=1 (same graph)   keyboard/nss-english.nsslm
  after        the working tree, default options                   keyboard/nss-english.nsslm
  after-generic, after-chat   the working tree                     artifacts/generic-final, --chat
  ngram        the working tree's n-gram tier                       -
BASELINE and PAPER are built with PAPER's harness plus fixed-prefix replay: the working
tree's harness sets EngineOptions fields that those trees do not have. Every arm runs
twice, in order and then reversed, to reduce order effects.

Sample: every 50th 'ac' row and every 5th 'nw' row of corpus/cases.tsv, in order.
Reported per arm: a typed word decoded in a fresh word session ('ac' ms), next-word
prediction (an 'nw' row's empty prefix, ms0) and keystrokes (prefixes 1..n-1, msk, all
replayed with KB_FULL_PREFIXES=1), each pooled over both runs, with the median per-request
ratio against `paper`; peak RSS and live heap at the end of the run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import tarfile
from compare_paper import BASELINE, build

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT / 'tools/evaluation/autocorrect'
PAPER = 'd77aa92d8937b871ffb36515a11647853d8e22ff'
ARTIFACTS = ROOT / 'tools/nss/artifacts'


def build_commit(commit, binary):
    harness = subprocess.run(['git', 'show', f'{PAPER}:tools/evaluation/autocorrect/IOSBench.cpp'],
                             check=True, cwd=ROOT, capture_output=True, text=True).stdout
    stop = 'if (kfound >= 0 && k >= 1) break;'
    assert harness.count(stop) == 1
    harness = harness.replace(stop, 'if (kfound >= 0 && k >= 1 && !std::getenv("KB_FULL_PREFIXES")) break;')
    with tempfile.TemporaryDirectory(prefix='nss-latency-build-') as directory:
        source = Path(directory)
        archive = source/'source.tar'
        subprocess.run(['git', 'archive', '--format=tar', '-o', str(archive), commit, 'native'], check=True, cwd=ROOT)
        with tarfile.open(archive) as tar:
            tar.extractall(source, filter='data')
        path = source/'tools/evaluation/autocorrect/IOSBench.cpp'
        path.parent.mkdir(parents=True)
        path.write_text(harness)
        build(source, binary)


def quantiles(values):
    values = sorted(values)
    return {f'p{int(p*100)}': values[min(len(values)-1, int(p*len(values)))] for p in (.5, .95, .99)} if values else None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--chat', type=Path, default=ARTIFACTS/'chat-final.nsslm')
    args = parser.parse_args()
    args.chat = args.chat.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    binaries ={name: BENCH/f'bin/nss-latency-{name}' for name in ('before', 'paper', 'after')}
    build_commit(BASELINE, binaries['before'])
    build_commit(PAPER, binaries['paper'])
    build(ROOT, binaries['after'])
    lines = (BENCH/'corpus/cases.tsv').read_text().splitlines()
    keep = set([l for l in lines if l.split('\t')[1] == 'ac'][::50] + [l for l in lines if l.split('\t')[1] == 'nw'][::5])
    sample = args.out/'latency.tsv'
    sample.write_text('\n'.join(l for l in lines if l in keep)+'\n')
    english = ROOT/'keyboard/nss-english.nsslm'
    arms = [('before', 'before', ARTIFACTS/'baseline-step8000.nsslm', {}),
            ('paper', 'paper', english, {}),
            ('after-paper', 'after', english, {'KB_NSS_PAPER': '1'}),
            ('after', 'after', english, {}),
            ('after-generic', 'after', ARTIFACTS/'generic-final.nsslm', {}),
            ('after-chat', 'after', args.chat, {}),
            ('ngram', 'after', None, {})]
    for name, _, model, _ in arms:
        if model and not model.exists():
            print(f'skipping {name}: no {model}', flush=True)
    arms = [arm for arm in arms if not arm[2] or arm[2].exists()]
    runs, rows = [], {}
    for index, (name, decoder, model, extra) in enumerate(arms + arms[::-1]):
        path = args.out/f'latency-{index:02d}-{name}.jsonl'
        env = {k: v for k, v in os.environ.items() if not k.startswith('KB_')}
        env.update(extra, KB_FULL_PREFIXES='1', **({'KB_NSS': str(model)} if model else {}))
        subprocess.run([str(binaries[decoder]), str(ROOT/'keyboard/langdata.bin'), str(ROOT/'keyboard/safety.kbguard'),
                        str(sample), str(path)], env=env, check=True)
        records = [json.loads(line) for line in path.read_text().splitlines()]
        assert records[-1].get('kind') == 'done'
        cases = {r['id']: r for r in records if 'id' in r}
        rows.setdefault(name, []).append(cases)
        end = [r for r in records if r.get('kind') == 'process' and r.get('at') == 'end']
        runs.append({'order': index, 'arm': name, 'events': records[-1]['events'],
                     'typed_word_ms': quantiles([r['ms'] for r in cases.values() if 'ms' in r]),
                     'next_word_ms': quantiles([r['ms0'] for r in cases.values() if 'ms0' in r]),
                     'keystroke_ms': quantiles([v for r in cases.values() for v in r.get('msk', [])]),
                     'process': end[0] if end else None})
        print(json.dumps(runs[-1]), flush=True)

    def timed(name):
        """(row id, position) -> (kind, mean ms over the arm's runs)."""
        out = {}
        for id, first in rows[name][0].items():
            kinds = ['typed_word'] if 'ms' in first else ['next_word'] + ['keystroke'] * len(first.get('msk', []))
            for k, kind in enumerate(kinds):
                values = [r[id]['ms'] if 'ms' in r[id] else ([r[id]['ms0']] + r[id].get('msk', []))[k] for r in rows[name]]
                out[(id, k)] = (kind, statistics.fmean(values))
        return out

    reference = timed('paper')
    summary = {}
    for name, *_ in arms:
        pooled, ratios = {}, {}
        for key, (kind, value) in timed(name).items():
            pooled.setdefault(kind, []).append(value)
            if reference[key][1] > 0:
                ratios.setdefault(kind, []).append(value / reference[key][1])
        ends = [r['process'] for r in runs if r['arm'] == name and r['process']]
        summary[name] = {kind: {'n': len(values), **quantiles(values), 'median_ratio_vs_paper': statistics.median(ratios[kind])}
                         for kind, values in pooled.items()}
        summary[name]['peak_rss_mib'] = max(e['peak_rss_bytes'] for e in ends) / 2**20
        summary[name]['heap_in_use_mib'] = max(e['heap_in_use_bytes'] for e in ends) / 2**20
    report = {'sample_sha256': hashlib.sha256(sample.read_bytes()).hexdigest(),
              'sampling': "Every 50th 'ac' row and every 5th 'nw' row of cases.tsv, preserving original order.",
              'scope': 'Desktop host with nothing else running; no physical-device latency claim. Two runs per arm, '
                       'in order then reversed. All sampled next-word prefixes replayed regardless of suggestion rank.',
              'compiler': subprocess.check_output(['clang++', '--version'], text=True).splitlines()[0],
              'arms': [{'name': n, 'decoder': d, 'model': str(m.relative_to(ROOT) if m.is_relative_to(ROOT) else m) if m else None, 'env': e} for n, d, m, e in arms],
              'models_sha256': {n: hashlib.sha256(m.read_bytes()).hexdigest() for n, _, m, _ in arms if m},
              'summary': summary, 'runs': runs}
    (args.out/'latency.json').write_text(json.dumps(report, indent=2)+'\n')
    for name, s in summary.items():
        print(f"{name:14} typed word p50 {s['typed_word']['p50']:7.3f} p95 {s['typed_word']['p95']:7.3f}"
              f" | next word p50 {s['next_word']['p50']:7.3f} | keystroke p50 {s['keystroke']['p50']:6.3f} p95 {s['keystroke']['p95']:6.3f}"
              f" | peak RSS {s['peak_rss_mib']:5.1f} MiB")


if __name__ == '__main__':
    main()
