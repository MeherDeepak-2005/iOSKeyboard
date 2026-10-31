#!/usr/bin/env python3
"""Build the shared test corpus (deterministic, seed 20261027).

Rows: id, kind (ac|nw), context, typed, target  ->  cases.tsv
Metadata per id (set, category, flags)          ->  cases-meta.json

Sets
  ecps      Real misspellings: CoreV4's ECPS ENGGB sentence pairs whose only
            difference is the last word. (CoreV4 test data: possible home advantage.)
  ecps_ok   The same contexts with the correct word typed (false-positive check).
  syn       MacKenzie & Soukoreff 500 phrases with one synthetic keyboard error per
            word: adjacent-key substitution, omission, adjacent insertion,
            transposition, double/undouble, two errors. Typos never form a word in
            either dictionary.
  realword  Synthetic errors that DO form a dictionary word in both packs (form->from).
  clean     Every MacKenzie word typed correctly in its context.
  hard      Hand-picked valid inputs a keyboard should leave alone (names, slang,
            tech terms, rare words, Indian English), no context.
  apos      Contractions typed without the apostrophe (dont -> don't).
  nw        Next-word / completion typing simulation over MacKenzie phrases.
"""
import json, os, pathlib, random, re, sys

HERE = pathlib.Path(__file__).resolve().parent
CORE = pathlib.Path(os.environ.get('COREV4', '/Users/meherdeepak/Downloads/CoreV4'))
INPUT = CORE/'v2core/tools/atxcoretest/data/input'
VOCAB = {
    'ios': [l.split('\t')[0] for l in pathlib.Path(sys.argv[1]).read_text().splitlines()],
    'core_us74': (CORE/'analysis/daily-use-audit/corev4-profile-words.txt').read_text().split('\n'),
    'core_in95': (CORE/'analysis/daily-use-audit/corev4-english_in-da2687ef-words.txt').read_text().split('\n'),
}
VOCAB = {k: {w.lower() for w in v if w} for k, v in VOCAB.items()}
ANY = set().union(*VOCAB.values())
ALL = set.intersection(*VOCAB.values())
rng = random.Random(20261027)

ROWS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
POS = {c: (x + (0, 0.5, 1.5)[y], y) for y, r in enumerate(ROWS) for x, c in enumerate(r)}
NEAR = {a: [b for b in POS if b != a and abs(POS[a][0] - POS[b][0]) <= 1.0 and abs(POS[a][1] - POS[b][1]) <= 1] for a in POS}

def letters(w): return [i for i, c in enumerate(w) if c in POS]
def sub(w):
    i = rng.choice(letters(w)); return w[:i] + rng.choice(NEAR[w[i]]) + w[i+1:]
def omit(w):
    i = rng.choice(letters(w)); return w[:i] + w[i+1:]
def insert(w):
    i = rng.choice(letters(w)); c = rng.choice(NEAR[w[i]])
    return w[:i] + c + w[i:] if rng.random() < .5 else w[:i+1] + c + w[i+1:]
def transpose(w):
    opts = [i for i in range(len(w) - 1) if w[i] != w[i+1] and w[i] in POS and w[i+1] in POS]
    if not opts: return None
    i = rng.choice(opts); return w[:i] + w[i+1] + w[i] + w[i+2:]
def double(w):
    dbl = [i for i in range(len(w) - 1) if w[i] == w[i+1]]
    if dbl and rng.random() < .6: i = rng.choice(dbl); return w[:i] + w[i+1:]
    i = rng.choice(letters(w)); return w[:i] + w[i] + w[i:]
def two(w):
    if len(w) < 5: return None
    a = rng.choice([sub, omit, insert, transpose])(w)
    return a and rng.choice([sub, omit, insert])(a)
OPS = {'sub_adjacent': sub, 'omission': omit, 'insertion': insert, 'transposition': transpose, 'double': double, 'two_errors': two}

rows, meta = [], {}
def add(set_, kind, context, typed, target, **extra):
    i = f'{set_}-{len(rows):05d}'
    rows.append((i, kind, context, typed, target))
    meta[i] = dict(set=set_, target=target.lower(), typed=typed,
                   in_ios=target.lower() in VOCAB['ios'], in_us74=target.lower() in VOCAB['core_us74'],
                   in_in95=target.lower() in VOCAB['core_in95'], **extra)

def clean(s): return s.replace('\r', '').replace('\t', ' ').strip()

# --- ECPS real misspellings
good = (INPUT/'ECPS/ENGGB_CorrectSentences.txt').read_text(encoding='utf-8-sig', errors='replace').splitlines()
bad = (INPUT/'ECPS/ENGGB_MisspelledSentences.txt').read_text(encoding='utf-8-sig', errors='replace').splitlines()
seen = set()
for g, b in zip(good, bad):
    g, b = clean(g), clean(b)
    gw, bw = g.rsplit(' ', 1) if ' ' in g else ('', g), b.rsplit(' ', 1) if ' ' in b else ('', b)
    if gw[0] != bw[0]: continue
    target, typed = gw[1], bw[1]
    if not re.fullmatch(r"[A-Za-z']+", target) or not re.fullmatch(r"[A-Za-z']+", typed): continue
    if typed.lower() == target.lower(): continue
    key = (gw[0].lower(), typed.lower())
    if key in seen: continue
    seen.add(key)
    add('ecps', 'ac', gw[0], typed, target, typo_is_word=typed.lower() in ANY)
    if (gw[0].lower(), target.lower()) not in seen:
        seen.add((gw[0].lower(), target.lower()))
        add('ecps_ok', 'ac', gw[0], target, target)

# --- MacKenzie phrases
phrases = [clean(l) for l in (INPUT/'MacPhrases.txt').read_text(errors='replace').splitlines() if clean(l)]
for p in phrases:
    words = p.split(' ')
    for i, w in enumerate(words):
        ctx = ' '.join(words[:i]); lw = w.lower()
        if not re.fullmatch(r"[a-z']+", lw): continue
        add('clean', 'ac', ctx, w, w)
        add('nw', 'nw', ctx, '', w)
        if len(lw) < 2: continue
        for name, op in OPS.items():
            made = None
            for _ in range(25):
                t = op(lw)
                if t and t != lw and t not in ANY and re.fullmatch(r"[a-z']+", t): made = t; break
            if made: add('syn', 'ac', ctx, made, w, error=name, length=len(lw))
        for _ in range(25):   # real-word error, when one exists
            t = rng.choice([sub, omit, insert, transpose])(lw)
            if t and t != lw and t in ALL and len(t) > 1:
                add('realword', 'ac', ctx, t, w, error='realword'); break

# --- contractions without apostrophes, in and out of context
contractions = ["don't", "can't", "won't", "isn't", "it's", "i'm", "i've", "i'll", "i'd", "you're", "we're", "they're",
                "didn't", "doesn't", "wasn't", "aren't", "couldn't", "wouldn't", "shouldn't", "haven't", "hasn't", "that's",
                "what's", "there's", "let's", "he's", "she's", "you'll", "we'll", "they'll", "you've", "we've", "they've",
                "weren't", "hadn't", "who's", "here's", "where's", "ain't", "y'all"]
for c in contractions:
    for ctx in ('', 'I think'):
        add('apos', 'ac', ctx, c.replace("'", ''), c, ambiguous=c.replace("'", '') in ALL)

# --- valid inputs that must not be changed
HARD = {
    'name': 'Priya Deepak Meher Siobhan Nguyen Krzysztof Aarav Saoirse Joaquin Xiomara Oluwaseun Zoey Aditi Raghav Tanvi Ishaan Niamh Dmitri Bjorn Yusuf',
    'brand_tech': 'iPhone GitHub Xcode kubernetes json npm wifi PyTorch TensorFlow Spotify Zomato Swiggy Paytm Figma Postgres nginx regex localhost async webhook',
    'slang': 'lol brb gonna wanna yeah nah omg tbh idk haha hmm okay ok lmao btw imo ikr smh yup nope',
    'rare_word': 'quixotic ephemeral sesquipedalian defenestrate petrichor syzygy ennui obsequious perspicacious lugubrious susurrus apricity callipygian halcyon mellifluous',
    'indian_english': 'lakh crore prepone dhaba chai kurta paneer biryani namaste jugaad',
    'abbrev': 'asap fyi eta rsvp diy aka faq ceo hr pdf',
}
for cat, ws in HARD.items():
    for w in ws.split():
        add('hard', 'ac', '', w, w, category=cat)

out = HERE/'corpus'
out.mkdir(exist_ok=True)
(out/'cases.tsv').write_text(''.join('\t'.join(r) + '\n' for r in rows))
(out/'cases-meta.json').write_text(json.dumps(meta) + '\n')
counts = {}
for m in meta.values(): counts[m['set']] = counts.get(m['set'], 0) + 1
syn = {}
for m in meta.values():
    if m['set'] == 'syn': syn[m['error']] = syn.get(m['error'], 0) + 1
print(json.dumps({'rows': len(rows), 'sets': counts, 'syn_errors': syn, 'phrases': len(phrases),
                  'vocab': {k: len(v) for k, v in VOCAB.items()}}, indent=1))
