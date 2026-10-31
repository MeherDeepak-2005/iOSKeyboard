#!/usr/bin/env python3
"""Build the independent misspelling sets (held-out only; neither engine was tuned on them).

Sources: Roger Mitton's public corpora (https://www.dcs.bbk.ac.uk/~ROGER/corpora.html),
downloaded into external/: missp.dat (Birkbeck), holbrook-missp.dat, aspell.dat,
wikipedia.dat. Format: "$correct" lines, each followed by its misspellings (Holbrook adds
a count). Rows keep only non-word errors whose lower-case, letters-only target is in all
three dictionaries (iOS, CoreV4 US-74k and IN-95k), so dictionary coverage does not decide
the result. Typed with no context.

Writes corpus/ext-cases.tsv and corpus/ext-cases-meta.json (sets ext_birkbeck, ext_holbrook,
ext_aspell, ext_wikipedia).
"""
import json, os, pathlib, re

HERE = pathlib.Path(__file__).resolve().parent
CORE = pathlib.Path(os.environ.get('COREV4', '/Users/meherdeepak/Downloads/CoreV4'))
VOCAB = {
    'ios': [l.split('\t')[0] for l in (HERE/'corpus/corpus-ios-vocab.tsv').read_text().splitlines()],
    'core_us74': (CORE/'analysis/daily-use-audit/corev4-profile-words.txt').read_text().split('\n'),
    'core_in95': (CORE/'analysis/daily-use-audit/corev4-english_in-da2687ef-words.txt').read_text().split('\n'),
}
VOCAB = {k: {w.lower() for w in v if w} for k, v in VOCAB.items()}
ANY = set().union(*VOCAB.values())
ALL = set.intersection(*VOCAB.values())
WORD = re.compile(r"[a-z]+")

rows, meta, seen = [], {}, set()
for name, path in (('birkbeck', 'missp.dat'), ('holbrook', 'holbrook-missp.dat'), ('aspell', 'aspell.dat'), ('wikipedia', 'wikipedia.dat')):
    target = None
    for line in (HERE/'external'/path).read_text(errors='replace').splitlines():
        line = line.strip()
        if line.startswith('$'): target = line[1:].lower(); continue
        typed = line.split()[0].lower() if line.split() else ''
        if not target or not WORD.fullmatch(target) or not WORD.fullmatch(typed): continue
        if target not in ALL or typed in ANY or typed == target or (name, typed, target) in seen: continue
        seen.add((name, typed, target))
        i = f'ext_{name}-{len(rows):05d}'
        rows.append((i, 'ac', '', typed, target))
        meta[i] = dict(set=f'ext_{name}', target=target, typed=typed, in_ios=True, in_us74=True, in_in95=True, typo_is_word=False)
(HERE/'corpus/ext-cases.tsv').write_text(''.join('\t'.join(r) + '\n' for r in rows))
(HERE/'corpus/ext-cases-meta.json').write_text(json.dumps(meta) + '\n')
counts = {}
for m in meta.values(): counts[m['set']] = counts.get(m['set'], 0) + 1
print(counts)
