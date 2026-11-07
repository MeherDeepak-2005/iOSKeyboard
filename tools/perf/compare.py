#!/usr/bin/env python3
"""Side-by-side table of tools/perf/device_perf.sh results.
   python3 tools/perf/compare.py results/before.json results/after.json [...]
Memory rows are what the engine adds over the test host's own footprint."""
import json
import pathlib
import sys

runs = [(pathlib.Path(p).stem, json.loads(pathlib.Path(p).read_text())) for p in sys.argv[1:]]
if not runs:
    sys.exit(__doc__)


def row(label, values, unit):
    cells = ''.join(f'{v:>14.2f}' if isinstance(v, (int, float)) else f'{"-":>14}' for v in values)
    print(f'{label:<34}{cells}  {unit}')


print(f'{"":<34}' + ''.join(f'{name[:13]:>14}' for name, _ in runs))
row('engine start', [r.get('initMs') for _, r in runs], 'ms')
row('first decode', [r.get('firstDecodeMs') for _, r in runs], 'ms')
for key, label in [('afterInitMB', 'memory after start'), ('afterFirstDecodeMB', 'memory after first decode'), ('peakMB', 'memory peak')]:
    row(label, [r[key] - r['baselineMB'] if key in r else None for _, r in runs], 'MB')
for phase in ('cold', 'warm'):
    for op, label in [('keystroke', 'keystroke'), ('prediction', 'next-word prediction'), ('glide', 'glide (final API)'),
                      ('swipeFirstPreview', 'swipe first preview'), ('swipePreview', 'swipe preview'), ('swipeFinish', 'swipe at lift')]:
        for stat in ('p50', 'p99', 'max'):
            row(f'{phase} {label} {stat}', [r.get(phase, {}).get(op, {}).get(stat) for _, r in runs], 'ms')
view = [r.get('keyboardView', {}) for _, r in runs]
row('key view build (first)', [v.get('firstMs') for v in view], 'ms')
row('key view build p50', [v.get('p50Ms') for v in view], 'ms')
row('key view memory', [v.get('perViewMB') for v in view], 'MB')
