#!/usr/bin/env python3
"""Autocorrect benchmark for the shared C++ engine, scored against CoreV4.

  evaluate.py build [--bin NAME] [--tuning]
                                       compile ios-bench (or bin/NAME) from the current native/ tree
  evaluate.py run NAME [--diag] [--quick] [--taps]
                                       run it over corpus/ -> results/NAME.jsonl; --quick runs
                                       only the tune half, without prediction or external sets
  evaluate.py score NAME [--vs REF] [--split held|tune|all] [--json OUT]
  evaluate.py golden [--write]         regenerate the shared-engine decode goldens; print every
                                       visible change (correction or suggestions); --write saves them
  evaluate.py core                     build CoreV4's harness and run it on corpus/ext-cases.tsv
                                       (the main corpus reuses CoreV4's stored 27 Oct results)

Scoring (same rules as the 27 Oct comparison):
  committed word = the engine's correction, else the typed text;
  suggestion slots = correction first, then the list, minus the typed text, first three;
  comparisons are case-insensitive.

Every word set is split by a hash of the *target* word, so no word is in both halves.
Tune constants on `tune`; report `held`. `--vs` (default: baseline) is the paired
comparison; a guardrail fails when it gets worse with exact McNemar p < 0.05, or a
latency percentile rises by more than 10%. score exits 1 when any guardrail fails.
CoreV4 is the fixed reference (COREV4_RESULTS, default: its US-74k medium run).
"""
import argparse, hashlib, json, math, os, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
CORPUS = HERE/'corpus'
RESULTS = HERE/'results'
BIN = HERE/'bin'
COREV4 = pathlib.Path(os.environ.get('COREV4', '/Users/meherdeepak/Downloads/CoreV4'))
CORE_RESULTS = pathlib.Path(os.environ.get('COREV4_RESULTS',
    COREV4/'analysis/autocorrect-comparison-2026-10-27/results/core-us74-medium.fwd.jsonl'))


def build(binary='ios-bench', tuning=False):
    cmake = (REPO/'native/CMakeLists.txt').read_text()
    start = cmake.index('add_library(DecoderCore STATIC')
    sources = [str(REPO/'native'/l.strip()) for l in cmake[start:cmake.index(')', start)].splitlines()[1:] if l.strip().endswith('.cpp')]
    BIN.mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-Os', '-DNDEBUG', *(['-DKB_TUNING'] if tuning else []), '-I', str(REPO/'native/DecoderCore/include'),
                    str(HERE/'IOSBench.cpp'), *sources, '-o', str(BIN/binary)], check=True)
    print(BIN/binary)


def run(name, diag, quick, binary='ios-bench', taps=False):
    RESULTS.mkdir(exist_ok=True)
    env = dict(os.environ, KB_DIAG='1' if diag else '0')
    out = RESULTS/f'{name}{".diag" if diag else ""}.jsonl'
    keyboard = REPO/'keyboard'
    corpora = sorted(CORPUS.glob('*cases.taps.tsv' if taps else '*cases.tsv'))
    if quick:
        meta = json.loads((CORPUS/'cases-meta.json').read_text())
        keep = lambda i: meta[i]['set'] in ('hard', 'apos') or (meta[i]['set'] != 'nw' and half(meta[i]) == 'tune')
        lines = [l for l in (CORPUS/'cases.tsv').read_text().splitlines(True) if keep(l.split('\t', 1)[0])]
        (CORPUS/'quick.tsv').write_text(''.join(lines))
        corpora = [CORPUS/'quick.tsv']
    for cases in corpora:
        part = out if cases.name in ('cases.tsv', 'cases.taps.tsv', 'quick.tsv') else out.with_name(f'{out.stem}.{cases.name.split("-")[0]}.jsonl')
        subprocess.run([str(BIN/binary), str(keyboard/'langdata.bin'), str(keyboard/'safety.kbguard'), str(cases), str(part)],
                       env=env, check=True, stderr=subprocess.DEVNULL)
        print(part)


def golden(write):
    """GenGolden.cpp decodes fixtures/shared-engine/corpus.json like EngineTests' replay."""
    fixtures = REPO/'tools/evaluation/fixtures/shared-engine'
    cmake = (REPO/'native/CMakeLists.txt').read_text()
    start = cmake.index('add_library(DecoderCore STATIC')
    sources = [str(REPO/'native'/l.strip()) for l in cmake[start:cmake.index(')', start)].splitlines()[1:] if l.strip().endswith('.cpp')]
    BIN.mkdir(exist_ok=True)
    subprocess.run(['xcrun', 'clang++', '-std=c++20', '-O1', '-I', str(REPO/'native/DecoderCore/include'), '-I', str(REPO/'native/tests'),
                    str(HERE/'GenGolden.cpp'), *sources, '-o', str(BIN/'gengolden')], check=True)
    lines = subprocess.run([str(BIN/'gengolden'), str(REPO/'keyboard/langdata.bin'), str(REPO), str(fixtures)],
                           check=True, capture_output=True, text=True).stdout.splitlines()
    def fix(x):   # JSONSerialization writes 2.0 as 2
        if isinstance(x, float) and x.is_integer(): return int(x)
        if isinstance(x, list): return [fix(v) for v in x]
        if isinstance(x, dict): return {k: fix(v) for k, v in x.items()}
        return x
    new = [fix(json.loads(l)) for l in lines]
    old = json.loads((fixtures/'golden-corpus.json').read_text())
    corpus = {c['id']: c for c in json.loads((fixtures/'corpus.json').read_text())}
    changed = [(o, n) for o, n in zip(old, new) if o != n]
    visible = [(o, n) for o, n in changed if (o['correction'], o['suggestions']) != (n['correction'], n['suggestions'])]
    print(f'{len(changed)} of {len(new)} goldens differ; {len(visible)} visibly')
    for o, n in visible:
        c = corpus.get(o['id'], {})
        print(f"  {o['id']} {c.get('typed')!r} ctx={c.get('context')}: {o['correction']} {o['suggestions']} -> {n['correction']} {n['suggestions']}")
    if write: (fixtures/'golden-corpus.json').write_text(json.dumps(new, sort_keys=True, indent=1) + '\n')


def core():
    """CoreV4 US-74k, medium mode, fresh profile: the 27 Oct configuration."""
    import shutil
    native = pathlib.Path(os.environ.get('COREV4_NATIVE', '/private/tmp/corev4-smoothing-native'))
    link = json.loads((native/'link-command.json').read_text())
    BIN.mkdir(exist_ok=True)
    cmd = [str(HERE/'CoreBench.cpp') if t.endswith('CoreMain.cpp') else str(BIN/'corev4-bench') if t.endswith('corev4-smoke') else t for t in link]
    subprocess.run(cmd, check=True)
    profile = BIN/'corev4-profile'
    if profile.exists(): shutil.rmtree(profile)
    shutil.copytree(native/'profile-us74', profile)
    for generated in [profile/'Profile.ata', *profile.glob('Dictionaries/*.itn')]: generated.unlink(missing_ok=True)
    RESULTS.mkdir(exist_ok=True)
    for cases in ('ext', 'keep'):
        subprocess.run([str(BIN/'corev4-bench'), str(profile), str(CORPUS/f'{cases}-cases.tsv'), str(RESULTS/f'corev4.{cases}.jsonl'), 'engus', 'medium'],
                       check=True, stderr=subprocess.DEVNULL)
        print(RESULTS/f'corev4.{cases}.jsonl')


def load(path):
    rows, info = {}, {}
    path = pathlib.Path(path)
    for p in [path, *sorted(path.parent.glob(f'{path.stem}.*.jsonl'))]:
        if not p.exists() or p.name.endswith('.diag.jsonl') and not path.name.endswith('.diag.jsonl'): continue
        for line in open(p):
            r = json.loads(line)
            if 'id' in r: rows[r['id']] = r
            else: info.setdefault(r['kind'], []).append(r)
    return rows, info


def norm(s): return ' '.join((s or '').lower().split())
def commit(r, m): return norm(r['c']) if r.get('c') else norm(m['typed'])
def slots(r, m):
    out = []
    for w in ([r['c']] if r.get('c') else []) + r.get('s', []):
        w = norm(w)
        if w != norm(m['typed']) and w not in out: out.append(w)
    return out[:3]
def half(m): return 'tune' if int(hashlib.sha1(m.get('key', m['target']).encode()).hexdigest(), 16) % 2 == 0 else 'held'
def mcnemar(b, c):
    n = b + c
    if not n: return 1.0
    if n > 2000: return math.erfc((abs(b - c) - 1) / math.sqrt(n) / math.sqrt(2))
    return min(1.0, 2 * sum(math.comb(n, i) for i in range(min(b, c) + 1)) / 2**n)
def quantile(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))] if xs else float('nan')


def metrics(meta):
    """name -> (ids, per-item predicate(r, m), higher_is_better, guardrail)."""
    by = {}
    for i, m in meta.items(): by.setdefault(m['set'], []).append(i)
    pick = lambda f: [i for i, m in meta.items() if f(m)]
    first_wrong = lambda m: m['typed'][:1].lower() != m['target'][:1]
    missing_first = lambda m: first_wrong(m) and m['typed'].lower() == m['target'][1:]
    swapped_first = lambda m: first_wrong(m) and len(m['typed']) > 1 and m['typed'][:2].lower() == m['target'][1::-1]
    fixed = lambda r, m: commit(r, m) == m['target']
    top3 = lambda r, m: fixed(r, m) or m['target'] in slots(r, m)
    left = lambda r, m: commit(r, m) == norm(m['typed'])
    changed = lambda r, m: commit(r, m) != norm(m['typed'])
    out = {
        'ECPS real misspellings fixed': (by.get('ecps', []), fixed, True, False),
        'ECPS target in top 3': (by.get('ecps', []), top3, True, False),
        'ECPS left uncorrected': (by.get('ecps', []), left, False, False),
        'ECPS missing first letter fixed': (pick(lambda m: m['set'] == 'ecps' and missing_first(m)), fixed, True, False),
        'ECPS other first letter fixed': (pick(lambda m: m['set'] == 'ecps' and first_wrong(m) and not missing_first(m) and not swapped_first(m)), fixed, True, False),
        'ECPS first two swapped fixed': (pick(lambda m: m['set'] == 'ecps' and swapped_first(m)), fixed, True, False),
        'Synthetic typos fixed': (by.get('syn', []), fixed, True, False),
        'Synthetic target in top 3': (by.get('syn', []), top3, True, False),
        'Synthetic left uncorrected': (by.get('syn', []), left, False, False),
        'Synthetic first letter wrong fixed': (pick(lambda m: m['set'] == 'syn' and first_wrong(m)), fixed, True, False),
    }
    for e in ('omission', 'insertion', 'sub_adjacent', 'double', 'transposition', 'two_errors'):
        out[f'  syn {e} fixed'] = (pick(lambda m, e=e: m['set'] == 'syn' and m.get('error') == e), fixed, True, False)
    out['  syn omission in top 3'] = (pick(lambda m: m['set'] == 'syn' and m.get('error') == 'omission'), top3, True, False)
    for s in sorted(k for k in by if k.startswith('ext_')):
        out[f'{s} fixed'] = (by[s], fixed, True, False)
        out[f'{s} in top 3'] = (by[s], top3, True, False)
    out.update({
        'GUARD false corrections, MacKenzie clean': (by.get('clean', []), changed, False, True),
        'GUARD false corrections, ECPS correct': (by.get('ecps_ok', []), changed, False, True),
        'GUARD hard valid words changed': (by.get('hard', []), changed, False, True),
        # make_keep.py: text the user meant that is not in the iOS vocabulary.
        'GUARD unknown names changed': (by.get('keep_name', []) + by.get('keep_name_ctx', []), changed, False, True),
        'GUARD unknown slang changed': (by.get('keep_slang', []), changed, False, True),
        'GUARD rare dictionary words changed': (by.get('keep_word', []), changed, False, True),
        'GUARD correct plurals stripped': (pick(lambda m: m['set'] in ('clean', 'ecps_ok') and m['target'].endswith('s') and len(m['target']) > 3),
                                           lambda r, m: commit(r, m) == m['target'][:-1], False, True),
        'GUARD real-word errors fixed': (by.get('realword', []), fixed, True, True),
        # make_contractions.py: real sentences, a word typed without its apostrophe.
        'Contractions restored in sentences': (by.get('contraction', []), fixed, True, False),
        'Contractions in top 3 in sentences': (by.get('contraction', []), top3, True, False),
        'GUARD plain word changed in sentences': (by.get('contraction_plain', []), changed, False, True),
        'GUARD contractions restored': (by.get('apos', []), fixed, True, True),
        'GUARD next word in top 3': (by.get('nw', []), lambda r, m: r['r0'] >= 0, True, True),
    })
    return out


def score(name, vs, split, json_out):
    meta = json.loads((CORPUS/'cases-meta.json').read_text())
    for extra in sorted(CORPUS.glob('*-cases-meta.json')): meta.update(json.loads(extra.read_text()))
    if split != 'all': meta = {i: m for i, m in meta.items() if m['set'] in ('hard', 'apos') or half(m) == split}
    runs = {'new': load(RESULTS/f'{name}.jsonl'), 'ref': load(RESULTS/f'{vs}.jsonl'), 'core': load(CORE_RESULTS)}
    for extra in ('corev4.ext.jsonl', 'corev4.keep.jsonl'): runs['core'][0].update(load(RESULTS/extra)[0])
    failed, report = [], {'run': name, 'vs': vs, 'split': split, 'metrics': {}}
    print(f'{name} vs {vs} · split={split} · CoreV4 = {CORE_RESULTS.name}\n')
    print(f'{"metric":44}{"n":>7}{vs[:10]:>11}{name[:10]:>11}{"CoreV4":>9}  +new/-new  p')
    for label, (ids, pred, up, guard) in metrics(meta).items():
        ids = [i for i in ids if i in runs['new'][0] and i in runs['ref'][0]]
        if not ids: continue
        val = {k: [bool(pred(rows[i], meta[i])) for i in ids] if all(i in rows for i in ids) else None for k, (rows, _) in runs.items()}
        rate = {k: 100 * sum(v) / len(v) if v else None for k, v in val.items()}
        b = sum(x and not y for x, y in zip(val['new'], val['ref'])); c = sum(y and not x for x, y in zip(val['new'], val['ref']))
        p = mcnemar(b, c)
        worse = (b < c) if up else (b > c)
        bad = guard and worse and p < 0.05
        if bad: failed.append(label)
        core = f'{rate["core"]:8.2f}%' if rate['core'] is not None else '        -'
        print(f'{label:44}{len(ids):>7}{rate["ref"]:10.2f}%{rate["new"]:10.2f}%{core} {b:>5}/{c:<5}{p:8.1e}{"  FAIL" if bad else ""}')
        report['metrics'][label] = dict(n=len(ids), ref=rate['ref'], new=rate['new'], core=rate['core'], gained=b, lost=c, p=p, guardrail=guard, failed=bad)
    # Keystroke savings and latency are not paired-binary: thresholded instead.
    nw = [i for i, m in meta.items() if m['set'] == 'nw' and i in runs['new'][0] and i in runs['ref'][0]]
    def savings(rows): return 100 * sum(rows[i]['len'] - rows[i]['kf'] for i in nw) / sum(rows[i]['len'] + 1 for i in nw) if nw else float('nan')
    def lat(rows, ids, key='ms'): return [rows[i][key] for i in ids if key in rows[i]]
    typo = [i for i, m in meta.items() if m['set'] in ('ecps', 'syn') and i in runs['new'][0] and i in runs['ref'][0]]
    keys = lambda rows: [x for i in nw for x in rows[i].get('msk', [])]
    extra = [('GUARD keystroke savings', savings(runs['ref'][0]), savings(runs['new'][0]), savings(runs['core'][0]), 0.5, True)]
    for q in (0.5, 0.95, 0.99):
        extra.append((f'GUARD typo request p{int(q*100)} ms', quantile(lat(runs['ref'][0], typo), q), quantile(lat(runs['new'][0], typo), q),
                      quantile(lat(runs['core'][0], typo), q), None, False))
    extra.append(('GUARD per-keystroke p95 ms', quantile(keys(runs['ref'][0]), .95), quantile(keys(runs['new'][0]), .95), None, None, False))
    print()
    for label, ref, new, core, slack, up in extra:
        if math.isnan(new): continue
        bad = (new < ref - slack) if up else (new > 1.10 * ref and new - ref > 0.05)
        if bad: failed.append(label)
        print(f'{label:44}{"":>7}{ref:11.3f}{new:11.3f}{core if core is not None else float("nan"):9.3f}{"  FAIL" if bad else ""}')
        report['metrics'][label] = dict(ref=ref, new=new, core=core, failed=bad)
    for k, (_, info) in runs.items():
        for p in info.get('process', []):
            if p['at'] == 'end': print(f'memory {k:5} peak RSS {p["peak_rss_bytes"]/2**20:6.1f} MB, footprint {p["footprint_bytes"]/2**20:6.1f} MB')
    report['failed'] = failed
    print('\nguardrails:', 'all pass' if not failed else 'FAILED: ' + ', '.join(failed))
    if json_out: pathlib.Path(json_out).write_text(json.dumps(report, indent=1) + '\n')
    return 1 if failed else 0


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build'); b.add_argument('--bin', default='ios-bench'); b.add_argument('--tuning', action='store_true', help='read KB_<constant> overrides from the environment'); sub.add_parser('core'); g = sub.add_parser('golden'); g.add_argument('--write', action='store_true')
    r = sub.add_parser('run'); r.add_argument('name'); r.add_argument('--diag', action='store_true'); r.add_argument('--quick', action='store_true'); r.add_argument('--bin', default='ios-bench'); r.add_argument('--taps', action='store_true', help='use make_taps.py simulated touches')
    s = sub.add_parser('score'); s.add_argument('name'); s.add_argument('--vs', default='baseline')
    s.add_argument('--split', choices=('held', 'tune', 'all'), default='held'); s.add_argument('--json')
    a = ap.parse_args()
    if a.cmd == 'build': build(a.bin, a.tuning)
    elif a.cmd == 'core': core()
    elif a.cmd == 'golden': golden(a.write)
    elif a.cmd == "run": run(a.name, a.diag, a.quick, a.bin, a.taps)
    else: sys.exit(score(a.name, a.vs, a.split, a.json))
