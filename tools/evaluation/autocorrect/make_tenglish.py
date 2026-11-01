#!/usr/bin/env python3
"""Roman Telugu (Tenglish) words a user types between English words, which the keyboard should
leave alone -> corpus/tenglish-cases.tsv, tenglish-cases-meta.json.

Added 1 Nov 2026: committing more of the corrections NSS ranks first also risks "fixing" these
words; make_keep.py's names are the only other unknown-word guardrail. Words come from the
shipped Roman Telugu lexicon (keyboard/tenglish_lexicon.bin, KBXL v2/v3), heaviest first, without
English dictionary words. Each is typed after no context, after English ("i told him") and after
another Tenglish word. Split by word.
"""
import json, pathlib, random, struct
HERE = pathlib.Path(__file__).resolve().parent
CORPUS = HERE/'corpus'
LEXICON = HERE.parents[2]/'keyboard/tenglish_lexicon.bin'
WORDS = 600


def roman_words():
    data = LEXICON.read_bytes()
    _, _, keys, _, key_offset, variant_offset, blob_offset, _ = struct.unpack_from('<4s7I', data, 0)
    key, variant = struct.Struct('<IHHI'), struct.Struct('<IHHf')
    words = []
    for i in range(keys):
        start, length, count, first = key.unpack_from(data, key_offset + i * key.size)
        weight = max(variant.unpack_from(data, variant_offset + (first + j) * variant.size)[3] for j in range(count))
        words.append((weight, data[blob_offset + start:blob_offset + start + length].decode()))
    words.sort(key=lambda w: (-w[0], w[1]))
    return [w for _, w in words]


def main():
    vocab = {line.split('\t')[0].lower() for line in open(CORPUS/'corpus-ios-vocab.tsv')}
    words = [w for w in roman_words() if w.isalpha() and len(w) >= 3 and w not in vocab][:WORDS]
    random.seed(20261101)
    rows, meta = [], {}
    for k, word in enumerate(words):
        for v, context in enumerate(('', 'i told him', random.choice(words))):
            i = f'keep_tenglish-{k:04d}-{v}'
            rows.append(f'{i}\tac\t{context}\t{word}\t{word}\n')
            meta[i] = {'set': 'keep_tenglish', 'typed': word, 'target': word, 'key': word}
    (CORPUS/'tenglish-cases.tsv').write_text(''.join(rows))
    (CORPUS/'tenglish-cases-meta.json').write_text(json.dumps(meta))
    print(len(rows), 'rows;', ', '.join(words[:12]), '...')


if __name__ == '__main__':
    main()
