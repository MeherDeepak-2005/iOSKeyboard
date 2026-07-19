#!/usr/bin/env python3
"""Fit the glide harness noise model to REAL swipes (task #36).

Input: glide_capture.jsonl, produced on-device when KBSettings.glideCapture is on.
Gesture and explicit-label events share an opaque ID. Automatic commits are recorded
for debugging but are never treated as intent; only a user-picked alternative creates
an `intended` label. The path is already in grid coordinates (q=(0,0)…), so no keyboard
geometry is needed.

For every stroke with an explicit intended word, we compare the real path to that word's
IDEAL path (polyline through its letter centers) and measure:

  jitter    – RMS perpendicular deviation of interior samples from the ideal polyline
  endpoint  – extra offset of the first/last sample beyond interior jitter
  overshoot – how far past a corner the path travels before turning back

Output: the jitter / endJitter / overshoot to paste into main.swift's synthesize()
call, so `run.sh`'s grid search re-tunes sigma / freqLambda / gate to YOUR hand.

Usage:
  python3 calibrate.py [path/to/glide_capture.jsonl]
  (default: ./glide_capture.jsonl — copy it out of the App Group container first)
"""
import json
import math
import sys
from pathlib import Path

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
OFFS = [0.0, 0.5, 1.5]
POS = {ch: (c + OFFS[r], float(r)) for r, row in enumerate(ROWS) for c, ch in enumerate(row)}


def ideal_path(word):
    pts, last = [], None
    for ch in word.lower():
        if ch == "'" or ch == last:
            continue
        if ch not in POS:
            return None
        pts.append(POS[ch]); last = ch
    return pts if len(pts) >= 2 else None


def seg_dist(p, a, b):
    ax, ay = a; bx, by = b; px, py = p
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def poly_dist(p, poly):
    return min(seg_dist(p, poly[i], poly[i + 1]) for i in range(len(poly) - 1))


def main():
    src = Path(sys.argv[1] if len(sys.argv) > 1 else "glide_capture.jsonl")
    if not src.exists():
        sys.exit(f"no capture file at {src} — enable Glide capture in the app, swipe ~50 "
                 f"words, then copy glide_capture.jsonl out of the App Group container.")

    records = []
    labels = {}
    for line in src.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if rec.get("event") == "label" and rec.get("id") and rec.get("intended"):
            labels[rec["id"]] = rec["intended"]
        elif rec.get("event") == "gesture":
            records.append(rec)

    jit, end, over, n = [], [], [], 0
    for rec in records:
        word = labels.get(rec.get("id"))
        path = rec.get("path")
        if not word or not path or len(path) < 4:
            continue
        poly = ideal_path(word)
        if not poly:
            continue
        n += 1
        interior = [poly_dist(p, poly) for p in path[2:-2]]
        if interior:
            jit.append(math.sqrt(sum(d * d for d in interior) / len(interior)))
        end.append(max(poly_dist(path[0], poly), poly_dist(path[-1], poly)))
        # overshoot: farthest a point sits beyond the far end of its nearest segment vertex
        over.append(max((poly_dist(p, poly) for p in path), default=0))

    if n == 0:
        sys.exit("no explicitly labelled strokes (pick a Glide alternative for each "
                 "calibration gesture; automatic commits are intentionally unlabelled).")

    def med(xs):
        xs = sorted(xs); return xs[len(xs) // 2] if xs else 0.0

    jitter = med(jit)
    endj = max(0.0, med(end) - jitter)
    overshoot = med(over)
    print(f"strokes analysed: {n}")
    print(f"  jitter (RMS dev from ideal): {jitter:.3f} key-widths")
    print(f"  endpoint extra offset:       {endj:.3f}")
    print(f"  overshoot (max dev):         {overshoot:.3f}")
    print("\nPaste into tools/glide_eval/main.swift synthesize(...) then re-run ./run.sh:")
    print(f"  jitter: {jitter:.2f}, endJitter: {endj:.2f}, overshoot: {overshoot:.2f}")


if __name__ == "__main__":
    main()
