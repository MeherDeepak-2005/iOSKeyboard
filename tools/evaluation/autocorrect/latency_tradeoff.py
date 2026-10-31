#!/usr/bin/env python3
"""Typing latency (corpus/keystrokes.tsv, one letter at a time) and tune-half accuracy for
KB_<constant> settings of a --tuning build. Latency runs are sequential so they do not
compete with each other; accuracy runs reuse tune.evaluate's cache.

  latency_tradeoff.py BIN '{"deletionCost": 1.1}' '{"deletionCost": 1.6}' ...
"""
import concurrent.futures as cf, json, os, subprocess, sys
import evaluate as ev, tune

def keystrokes(binary, setting):
    out = ev.RESULTS/'ks'/f'{binary}-{tune.json.dumps(setting, sort_keys=True)}.jsonl'.replace(' ', '').replace('"', '')
    out.parent.mkdir(exist_ok=True)
    keyboard = ev.REPO/'keyboard'
    subprocess.run([str(ev.BIN/binary), str(keyboard/'langdata.bin'), str(keyboard/'safety.kbguard'), str(ev.CORPUS/'keystrokes.tsv'), str(out)],
                   env=dict(os.environ, **{f'KB_{k}': str(v) for k, v in setting.items()}), check=True, stderr=subprocess.DEVNULL)
    short, long = [], []
    for r in map(json.loads, open(out)):
        for k, ms in enumerate(r.get('msk', []), 1): (short if k <= 4 else long).append(ms)
    return ev.quantile(short, .95), ev.quantile(long, .5), ev.quantile(long, .95), sum(short) + sum(long)

binary, settings = sys.argv[1], [json.loads(s) for s in sys.argv[2:]]
tune.BINARY = binary
lat = [keystrokes(binary, s) for s in settings]
base = ev.load(ev.RESULTS/'baseline.jsonl')[0]
with cf.ThreadPoolExecutor(4) as pool:
    for s, l, (_, rows) in zip(settings, lat, pool.map(tune.evaluate, settings)):
        score, reasons, info = tune.judge(rows, base)
        print(json.dumps(s), f'| keys1-4 p95 {l[0]:.3f} | keys5+ p50 {l[1]:.3f} p95 {l[2]:.3f} | total {l[3]/1000:.1f}s |',
              f'objective {score:.3f}', {k: round(v, 2) for k, v in info.items()}, reasons or '', flush=True)
