#!/usr/bin/env python3
"""Contractions typed without their apostrophe, in real sentences (Tatoeba English,
tools/.cache/corpora/eng_sentences.tsv.bz2) -> corpus/contraction-cases.tsv, contraction-cases-meta.json.

Added 1 Nov 2026: the strip showed "it's"/"how's" first while Space kept "its"/"hows". The apos set
has no row where the plain word was meant ("the dog wagged its tail"), so it cannot price a rule
that restores real-word contractions. Every row is a word that is also a dictionary word without
its apostrophe; context is the sentence before it. Sets: contraction (the sentence wrote the
contraction) and contraction_plain (it wrote the plain word). Split by sentence, not target: the
target-hash split would put every "its" row in one half.
"""
import bz2, collections, json, pathlib, random, re
HERE = pathlib.Path(__file__).resolve().parent
CORPUS = HERE/'corpus'
SOURCE = HERE.parents[1]/'.cache/corpora/eng_sentences.tsv.bz2'
PAIRS = {"its": "it's", "were": "we're", "well": "we'll", "ill": "i'll", "shed": "she'd", "hell": "he'll",
         "wed": "we'd", "lets": "let's", "cant": "can't", "wont": "won't", "id": "i'd", "shell": "she'll",
         "hows": "how's", "whys": "why's", "hed": "he'd", "shes": "she's", "hes": "he's", "whos": "who's"}
FORMS = {**{p: p for p in PAIRS}, **{c: p for p, c in PAIRS.items()}}
PER_FORM = 400
TOKEN = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)?")


def main():
    found = collections.defaultdict(list)
    with bz2.open(SOURCE, 'rt', encoding='utf-8') as lines:
        for line in lines:
            parts = line.rstrip('\n').split('\t')
            if len(parts) != 3 or parts[1] != 'eng': continue
            sid, sentence = parts[0], parts[2]
            for match in TOKEN.finditer(sentence):
                form = match.group().replace('’', "'").lower()
                if form in FORMS:
                    found[form].append((sid, sentence[:match.start()], match.group().replace('’', '').replace("'", '')))
                    break
    random.seed(20261101)
    rows, meta = [], {}
    for form in sorted(found):
        plain = FORMS[form]
        name = 'contraction_plain' if form == plain else 'contraction'
        for k, (sid, context, typed) in enumerate(random.sample(found[form], min(PER_FORM, len(found[form])))):
            i = f'{name}-{plain}-{k:04d}'
            rows.append(f'{i}\tac\t{context}\t{typed}\t{form}\n')
            meta[i] = {'set': name, 'typed': typed, 'target': form, 'key': sid}
    (CORPUS/'contraction-cases.tsv').write_text(''.join(rows))
    (CORPUS/'contraction-cases-meta.json').write_text(json.dumps(meta))
    counts = collections.Counter((m['set'], FORMS[m['target']]) for m in meta.values())
    print(len(rows), 'rows'); [print(f'  {s:18} {w:6} {n}') for (s, w), n in sorted(counts.items())]


if __name__ == '__main__':
    main()
