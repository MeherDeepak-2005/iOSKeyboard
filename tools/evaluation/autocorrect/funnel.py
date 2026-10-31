#!/usr/bin/env python3
"""Where iOSKeyboard loses the target on typo rows (needs a KB_DIAG=1 run).

Stages, first failing one wins:
  not_generated      no candidate pool produced the target
  cut_by_shortlist   generated, dropped by the 32-row pre-LM shortlist
  ranked_below_top   survived, but not ranked 1st (and not committed)
  not_committed      ranked 1st, but the correction gate did not fire / chose another form
Usage: funnel.py results/X.diag.jsonl [label]
"""
import collections, json, pathlib, sys
HERE = pathlib.Path(__file__).resolve().parent
META = json.loads((HERE/'corpus/cases-meta.json').read_text())
rows = {r['id']: r for r in map(json.loads, open(sys.argv[1])) if 'id' in r and 'pools' in r}
out = {}
for st in ('ecps', 'syn', 'realword'):
    c = collections.Counter(); pools = collections.Counter(); n = 0
    by_err = collections.defaultdict(collections.Counter)
    for i, m in META.items():
        if m['set'] != st: continue
        r = rows[i]; n += 1
        commit = (r['c'] or m['typed']).lower()
        if commit == m['target']: stage = 'fixed'
        elif not r['pools']: stage = 'not_generated'
        elif not r['sl']: stage = 'cut_by_shortlist'
        elif r['rk'] != 0: stage = 'ranked_below_top'
        else: stage = 'not_committed'
        c[stage] += 1
        if st == 'syn': by_err[m['error']][stage] += 1
        if stage != 'fixed' and r['pools']: pools[''.join(sorted(set(r['pools'])))] += 1
    out[st] = {'n': n, **{k: round(100 * v / n, 2) for k, v in c.items()}}
    if st == 'syn':
        out['syn_by_error'] = {e: {k: round(100 * v / sum(cc.values()), 1) for k, v in cc.items()} for e, cc in by_err.items()}
bad = [i for i in rows if META[i]['set'] in ('ecps', 'syn', 'realword') and rows[i]['rk'] >= 0 and (not rows[i]['pools'] or not rows[i]['sl'])]
out['consistency_violations_on_typo_rows'] = len(bad)
print(json.dumps(out, indent=1))
if len(sys.argv) > 2: (HERE/f'funnel-{sys.argv[2]}.json').write_text(json.dumps(out, indent=1) + '\n')
