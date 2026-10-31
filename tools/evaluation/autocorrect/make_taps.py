#!/usr/bin/env python3
"""Add simulated touch positions to the typo rows (deterministic, seed 20261027).

  make_taps.py [--sigma 0.35]   corpus/cases.tsv -> corpus/cases.taps.tsv (+ ext)

Production sends tap offsets; the 27 Oct comparison sent none. Each typed letter of an
autocorrect row gets one tap, in key widths from that key's centre, on the same grid as
native SpatialModel.cpp (rows offset 0, 0.5, 1.5). Typed and target are aligned by edit
distance. A letter that matches its target letter, or an extra letter, is a Gaussian
(sigma) around its own key; a substituted letter is a Gaussian around the *intended* key.
Either way the point is resampled until the typed key is the nearest key, so the tap is
always consistent with what was typed: an adjacent-key slip lands near the shared border.
Letters with no key (apostrophes, digits) and rows CoreV4 cannot use get no tap ("-").
"""
import argparse, pathlib, random

HERE = pathlib.Path(__file__).resolve().parent
ROWS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
KEY = {c: (x + (0, 0.5, 1.5)[y], float(y)) for y, r in enumerate(ROWS) for x, c in enumerate(r)}


def nearest(x, y): return min(KEY, key=lambda k: (KEY[k][0] - x) ** 2 + (KEY[k][1] - y) ** 2)


def align(typed, target):
    """Per typed letter: the target letter it stands for, or None for an inserted letter."""
    n, m = len(typed), len(target)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (typed[i-1] != target[j-1]))
    out, i, j = [None] * n, n, m
    while i > 0:
        if j > 0 and d[i][j] == d[i-1][j-1] + (typed[i-1] != target[j-1]): out[i-1] = target[j-1]; i -= 1; j -= 1
        elif d[i][j] == d[i-1][j] + 1: i -= 1
        else: j -= 1
    return out


def tap(rng, typed, intended, sigma):
    if typed not in KEY: return '-'
    cx, cy = KEY[intended] if intended in KEY else KEY[typed]
    for _ in range(200):
        x, y = rng.gauss(cx, sigma), rng.gauss(cy, sigma)
        if nearest(x, y) == typed: return f'{x - KEY[typed][0]:.3f},{y - KEY[typed][1]:.3f}'
    # Intended key too far for the typed key to be hit by a slip: an ordinary in-key tap.
    while True:
        x, y = rng.gauss(KEY[typed][0], sigma), rng.gauss(KEY[typed][1], sigma)
        if nearest(x, y) == typed: return f'{x - KEY[typed][0]:.3f},{y - KEY[typed][1]:.3f}'


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--sigma', type=float, default=0.35)
    a = ap.parse_args()
    rng = random.Random(20261027)
    for src in sorted((HERE/'corpus').glob('*cases.tsv')):
        out = []
        for line in src.read_text().splitlines():
            cols = line.split('\t')
            if cols[1] == 'ac' and cols[3]:
                typed, target = cols[3].lower(), cols[4].lower()
                cols.append(';'.join(tap(rng, t, i, a.sigma) for t, i in zip(typed, align(typed, target))))
            out.append('\t'.join(cols))
        (src.parent/src.name.replace('cases.tsv', 'cases.taps.tsv')).write_text('\n'.join(out) + '\n')
        print(src.name, '->', src.name.replace('cases.tsv', 'cases.taps.tsv'))


if __name__ == '__main__':
    main()
