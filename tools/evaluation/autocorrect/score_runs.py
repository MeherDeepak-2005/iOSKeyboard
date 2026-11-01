#!/usr/bin/env python3
"""Score several runs side by side against one reference, with evaluate.py's rules.

  score_runs.py REF RUN [RUN ...] [--split held|tune|all] [--json OUT]

The same metrics, split and exact McNemar test as `evaluate.py score`, without its
CoreV4 column (which needs CoreV4's stored results), plus keystroke savings. Each RUN
column is its rate; `gained/lost p` is the paired change against REF.
"""
import argparse, json
import evaluate as ev


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('ref'); ap.add_argument('runs', nargs='+')
    ap.add_argument('--split', default='held', choices=('held', 'tune', 'all')); ap.add_argument('--json')
    a = ap.parse_args()
    meta = json.loads((ev.CORPUS/'cases-meta.json').read_text())
    for extra in sorted(ev.CORPUS.glob('*-cases-meta.json')): meta.update(json.loads(extra.read_text()))
    if a.split != 'all': meta = {i: m for i, m in meta.items() if m['set'] in ('hard', 'apos') or ev.half(m) == a.split}
    names = [a.ref, *a.runs]
    rows = {n: ev.load(ev.RESULTS/f'{n}.jsonl')[0] for n in names}
    common = set.intersection(*(set(r) for r in rows.values()))
    report = {'ref': a.ref, 'runs': a.runs, 'split': a.split, 'metrics': {}}
    print(f'split={a.split}; reference = {a.ref}\n')
    print(f'{"metric":42}{"n":>6}' + ''.join(f'{n[:12]:>13}' for n in names) + ''.join(f'{"vs " + n[:14]:>22}' for n in a.runs))
    for label, (ids, pred, up, guard) in ev.metrics(meta).items():
        ids = [i for i in ids if i in common]
        if not ids: continue
        val = {n: [bool(pred(rows[n][i], meta[i])) for i in ids] for n in names}
        rate = {n: 100 * sum(v) / len(v) for n, v in val.items()}
        cells, entry = [], {'n': len(ids), 'higher_is_better': up, 'guardrail': guard, 'rates': rate, 'paired': {}}
        for n in a.runs:
            gained = sum(x and not y for x, y in zip(val[n], val[a.ref])); lost = sum(y and not x for x, y in zip(val[n], val[a.ref]))
            p = ev.mcnemar(gained, lost)
            bad = guard and ((gained < lost) if up else (gained > lost)) and p < .05
            cells.append(f'{gained:>6}/{lost:<6}{p:7.1e}{"!" if bad else "*" if p < .05 else " "}')
            entry['paired'][n] = {'gained': gained, 'lost': lost, 'p': p, 'guard_fail': bad}
        print(f'{label[:42]:42}{len(ids):>6}' + ''.join(f'{rate[n]:>12.2f}%' for n in names) + ''.join(cells))
        report['metrics'][label] = entry
    nw = [i for i, m in meta.items() if m['set'] == 'nw' and i in common]
    if nw:
        savings = {n: 100 * sum(rows[n][i]['len'] - rows[n][i]['kf'] for i in nw) / sum(rows[n][i]['len'] + 1 for i in nw) for n in names}
        print(f'{"keystroke savings (nw)":42}{len(nw):>6}' + ''.join(f'{savings[n]:>12.2f}%' for n in names))
        report['metrics']['keystroke savings'] = {'n': len(nw), 'rates': savings}
    print('\n* paired p < 0.05; ! guardrail regression (worse with p < 0.05)')
    if a.json: open(a.json, 'w').write(json.dumps(report, indent=1) + '\n')


if __name__ == '__main__':
    main()
