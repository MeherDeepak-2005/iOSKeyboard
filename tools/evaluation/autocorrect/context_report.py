#!/usr/bin/env python3
"""Context awareness: compare runs on the rows that have left context, by context length.

  context_report.py BASE RUN [RUN ...] [--split held|tune|all]

The keyboard will usually see context, so this leaves out the first word of a sentence
(rows whose parsed context is empty) and reports, for every run against BASE:
misspellings fixed (ECPS, synthetic) overall and by context length (the n-gram reads
at most two words, the NSS the whole sentence), real-word errors fixed, correct words
changed, unknown names changed in context, and next-word top 3. Contexts are parsed as
IOSBench.cpp parses them (contextWords: letters and apostrophes, stop at . ! ? newline,
at most 8 words). Pairs are tested with exact McNemar.
"""
import argparse, json
import evaluate as ev

BUCKETS = ((1, 1), (2, 2), (3, 4), (5, 8))


def context_words(raw: str, limit: int = 8) -> list[str]:
    word = lambda c: c.isalpha() or c == "'" or ord(c) >= 0x80
    words, end = [], len(raw)
    while end and word(raw[end - 1]): end -= 1
    while len(words) < limit:
        while end and not word(raw[end - 1]):
            if raw[end - 1] in '.!?\n': return words
            end -= 1
        if not end: break
        start = end
        while start and word(raw[start - 1]): start -= 1
        words.insert(0, raw[start:end].lower()); end = start
    return words


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('base'); ap.add_argument('runs', nargs='+'); ap.add_argument('--split', default='held')
    a = ap.parse_args()
    meta, raw = {}, {}
    for name in ('cases', 'keep-cases'):
        meta.update(json.loads((ev.CORPUS/f'{name}-meta.json').read_text()))
        for line in (ev.CORPUS/f'{name}.tsv').read_text().splitlines():
            p = line.split('\t'); raw[p[0]] = p[2]
    length = {i: len(context_words(raw[i] + ' ')) for i in raw}
    def load(name):
        rows = ev.load(ev.RESULTS/f'{name}.jsonl')[0]
        rows.update(ev.load(ev.RESULTS/f'{name}.keep.jsonl')[0])
        return rows
    base, runs = load(a.base), {r: load(r) for r in a.runs}
    keep = lambda i: i in base and length.get(i, 0) > 0 and (a.split == 'all' or ev.half(meta[i]) == a.split)
    fixed = lambda r, m: ev.commit(r, m) == m['target']
    changed = lambda r, m: ev.commit(r, m) != ev.norm(m['typed'])
    top3 = lambda r, m: r.get('r0', -1) in (0, 1, 2)
    by = lambda *sets: [i for i, m in meta.items() if m['set'] in sets and keep(i)]
    rows = [('Misspellings fixed (ECPS + synthetic)', by('ecps', 'syn'), fixed, True)]
    for lo, hi in BUCKETS:
        rows.append((f'  context {lo}' + (f'-{hi}' if hi > lo else '') + ' words',
                     [i for i in by('ecps', 'syn') if lo <= length[i] <= hi], fixed, True))
    rows += [('ECPS real misspellings fixed', by('ecps'), fixed, True),
             ('Synthetic typos fixed', by('syn'), fixed, True),
             ('Real-word errors fixed', by('realword'), fixed, True),
             ('Correct words changed (lower is better)', by('ecps_ok', 'clean'), changed, False),
             ('Unknown names changed in context (lower)', by('keep_name_ctx'), changed, False),
             ('Next word in top 3', by('nw'), top3, True)]
    names = list(runs)
    print(f'{a.split} half, rows with left context; base = {a.base}\n')
    print(f'{"metric":42}{"n":>7}{a.base[:13]:>14}' + ''.join(f'{n[:16]:>18}' for n in names))
    for label, ids, pred, up in rows:
        if not ids: continue
        line = f'{label:42}{len(ids):>7}{100 * sum(pred(base[i], meta[i]) for i in ids) / len(ids):>13.2f}%'
        for n in names:
            r = runs[n]
            good = [pred(r[i], meta[i]) for i in ids]; ref = [pred(base[i], meta[i]) for i in ids]
            gained = sum(g and not b for g, b in zip(good, ref)); lost = sum(b and not g for g, b in zip(good, ref))
            p = ev.mcnemar(gained, lost)
            mark = '' if p >= 0.05 else ('+' if (gained > lost) == up else '-')
            line += f'{100 * sum(good) / len(ids):>10.2f}% {mark:1}{p:5.0e}'.replace('e-0', 'e-')
        print(line)
    print('\n+/- : significantly better/worse than base (McNemar p < 0.05); the number after each rate is p.')


if __name__ == '__main__':
    main()
