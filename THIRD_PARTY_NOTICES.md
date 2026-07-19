# Third-Party Notices

## FrequencyWords English 2018

`keyboard/langdata.bin` contains a transformed subset of the FrequencyWords
English frequency list by hermitdave, pinned at commit
`525f9b560de45753a5ea01069454e72e9aa541c6`.

The FrequencyWords repository code is MIT licensed and its generated frequency
content is licensed under Creative Commons Attribution-ShareAlike 4.0
International. Glyph filters the list, adds project vocabulary and contractions,
and serializes it into a memory-mapped trie with frequency and language-model data.

- Source: https://github.com/hermitdave/FrequencyWords
- License: https://creativecommons.org/licenses/by-sa/4.0/

## Tatoeba English CC0 Sentences

The bi- and trigram counts in `keyboard/langdata.bin` are derived from the English
CC0-only Tatoeba sentence export snapshot vendored at
`tools/data/tatoeba-eng-cc0-2026-07-18.tsv.bz2`. Glyph lowercases and tokenizes the
sentences, counts bounded context tables, and does not ship sentence text in the app.

- Source: https://tatoeba.org/en/downloads
- Public-domain dedication: https://creativecommons.org/publicdomain/zero/1.0/

## Unicode Character Data

Emoji search keywords in `keyboard/emoji.bin` include names derived from Unicode
Character Database 14.0 data through Python's `unicodedata` module.

- Terms of use: https://www.unicode.org/license.txt

The full artifact paths, hashes, build scripts, and transformations are recorded in
`ARTIFACTS.json`.
