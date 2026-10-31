#!/usr/bin/env python3
"""Sweep the correction gate (KB_POLICY) on the tune half with the current engine.

  gate_sweep.py "3,5,3,0,0,1.6" "2,5,3,0,0,1.6" ...

Each value is Swift CorrectionPolicy.nativeValues order: oovMargin, realWordMargin,
closeRescueMargin, closeRescueGap, minimumCloseGap, closeRescueMaxCost. Prints tune.judge's
metrics plus the share of typos left uncorrected, against results/baseline.jsonl.
GATE_BIN picks the binary (default ios-p2); with a --tuning build, KB_<constant> variables
pass through and are part of the cached result's name.
"""
import concurrent.futures as cf, os, subprocess, sys
import evaluate as ev, tune

def run(policy):
    tag = '-'.join(f'{k[3:]}{v}' for k, v in sorted(os.environ.items()) if k.startswith('KB_') and k != 'KB_POLICY')
    out = ev.RESULTS/'gate'/f'{os.environ.get("GATE_BIN", "ios-p2")}{tag}-{policy.replace(",", "_")}.jsonl'
    out.parent.mkdir(exist_ok=True)
    if not out.exists():
        keyboard = ev.REPO/'keyboard'
        subprocess.run([str(ev.BIN/os.environ.get('GATE_BIN', 'ios-p2')), str(keyboard/'langdata.bin'), str(keyboard/'safety.kbguard'), str(tune.CASES), str(out) + '.part'],
                       env=dict(os.environ, KB_POLICY=policy), check=True, stderr=subprocess.DEVNULL)
        os.replace(str(out) + '.part', out)
    return policy, ev.load(out)[0]

base = ev.load(ev.RESULTS/'baseline.jsonl')[0]
with cf.ThreadPoolExecutor(4) as pool:
    for policy, rows in pool.map(run, sys.argv[1:]):
        score, reasons, info = tune.judge(rows, base)
        typo = [i for i in rows if tune.META[i]['set'] in ('ecps', 'syn')]
        left = 100 * sum(ev.commit(rows[i], tune.META[i]) == ev.norm(tune.META[i]['typed']) for i in typo) / len(typo)
        print(f'{policy:22} objective {score:.3f}  left {left:.2f}%', {k: round(v, 2) for k, v in info.items()}, reasons or '', flush=True)
