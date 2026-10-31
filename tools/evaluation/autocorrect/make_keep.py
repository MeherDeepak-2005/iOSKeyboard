#!/usr/bin/env python3
"""Text a keyboard should leave alone, from sources independent of every engine: proper names
and English words missing from the iOS vocabulary (macOS /usr/share/dict propernames, words)
and common slang/abbreviations missing from it. -> corpus/keep-cases.tsv, keep-cases-meta.json.

Added 28 Oct 2026: the other correct-word sets (MacKenzie clean, ECPS correct) are dictionary
words, so they only test the real-word gate; a typed non-word the user meant (a name) was
tested by the 95-word hard set alone. Split by target hash like every set: tune on tune.
"""
import json, pathlib, random
HERE = pathlib.Path(__file__).resolve().parent
CORPUS = HERE/'corpus'
SLANG = ['ew', 'kk', 'gn', 'ig', 'yw', 'ui', 'ux', 'ev', 'hbd', 'tbh', 'imo', 'idk', 'smh', 'brb', 'ngl', 'lmao',
         'omw', 'irl', 'fwiw', 'afaik', 'tldr', 'iirc', 'rofl', 'ikr', 'istg', 'fomo', 'yolo', 'bae', 'lit', 'sus',
         'vibe', 'vibes', 'rizz', 'yeet', 'stan', 'simp', 'bruh', 'fam', 'noob', 'meme', 'memes', 'selfie', 'emoji',
         'hashtag', 'unfollow', 'retweet', 'podcast', 'vlog', 'vlogger', 'blog', 'blogger', 'app', 'apps', 'wifi',
         'bluetooth', 'iphone', 'ipad', 'google', 'googled', 'facebook', 'instagram', 'tiktok', 'youtube',
         'youtuber', 'netflix', 'spotify', 'uber', 'zoom', 'covid', 'crypto', 'bitcoin', 'nft', 'ai', 'chatgpt',
         'gonna', 'wanna', 'gotta', 'kinda', 'sorta', 'dunno', 'lemme', 'gimme', 'ya', 'yall', "y'all", 'aint',
         'nah', 'yep', 'yup', 'nope', 'omg', 'lol', 'haha', 'hahaha', 'lmk', 'ttyl', 'np', 'thx', 'pls', 'plz',
         'u', 'ur', 'r', 'b4', 'gr8', '2nite', '2day']


def main():
    vocab = {line.split('\t')[0].lower() for line in open(CORPUS/'corpus-ios-vocab.tsv')}
    rows, meta = [], {}
    def add(i, context, text, name):
        rows.append(f'{i}\tac\t{context}\t{text}\t{text}\n'); meta[i] = {'set': name, 'typed': text, 'target': text.lower()}
    names = [w.strip() for w in open('/usr/share/dict/propernames') if w.strip()]
    for k, n in enumerate(n for n in names if n.isalpha() and n.lower() not in vocab):
        add(f'keep_name-{k:05d}-0', '', n, 'keep_name')
        add(f'keep_name-{k:05d}-1', 'i was talking to', n, 'keep_name_ctx')
    words = [w.strip() for w in open('/usr/share/dict/words')]
    words = [w for w in words if w.islower() and w.isalpha() and len(w) >= 3 and w not in vocab]
    random.seed(0)
    for k, w in enumerate(random.sample(words, 3000)): add(f'keep_word-{k:05d}', '', w, 'keep_word')
    for k, w in enumerate(w for w in SLANG if w not in vocab): add(f'keep_slang-{k:05d}', '', w, 'keep_slang')
    (CORPUS/'keep-cases.tsv').write_text(''.join(rows))
    (CORPUS/'keep-cases-meta.json').write_text(json.dumps(meta))
    print(len(rows), 'rows')


if __name__ == '__main__':
    main()
