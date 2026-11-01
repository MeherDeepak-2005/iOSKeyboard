# Glyph vs Apple's keyboard vs Gboard on an iPhone 17 (2 Nov 2026)

Glyph ran the official NSS configuration (raw, exact, unigram floor, generic-final). Apple's keyboard
was "English (India)"; Gboard 2.3.19; both with their default settings, not inspected.

`keyboardUITests.testCompareKeyboards` placed each case's context in a text field and tapped the
word's keys at their centres, then Space, through each keyboard selected from the globe menu.
Cases: `tools/evaluation/autocorrect/make_keyboard_comparison.py` (held-out half, 10 per bucket).
Every keyboard saw identical letters, so this compares correction, not touch handling. Raw lines:
`results.txt` (COMPARE keyboard bucket [context] typed -> committed [want] OK/MISS seconds).

| bucket (10 each) | Glyph | Apple | Gboard |
|---|---|---|---|
| misspelling, with context | 10 | 7 | 5 |
| misspelling | 7 | 6 | 6 |
| typo, with context | 9 | 9 | 8 |
| typo | 9 | 6 | 10 |
| severe (3+ edits), with context | 0 | 2 | 0 |
| severe (3+ edits) | 0 | 1 | 0 |
| Birkbeck (up to 2 edits) | 5 | 5 | 6 |
| real-word error, with context | 7 | 0 | 4 |
| real-word error | 1 | 1 | 0 |
| correct word kept, with context | 10 | 10 | 10 |
| correct word kept | 10 | 10 | 10 |
| rare dictionary word kept | 6 | 4 | 5 |
| name kept, with context | 5 | 10 | 7 |
| name kept | 2 | 8 | 6 |
| **errors fixed (of 90)** | **48** | 37 | 39 |
| **words kept (of 50)** | 33 | **42** | 38 |
| total right (of 140) | 81 | 79 | 77 |

Ten cases per bucket: a difference of one or two cases in a bucket is noise. Only the fixed/kept
totals and the larger bucket gaps (misspellings and real-word errors with context, names) carry
signal.
