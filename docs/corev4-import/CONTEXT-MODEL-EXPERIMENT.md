# CoreV4 English context extraction and comparison

20 October 2026. The active `keyboard/langdata.bin` remains KBLM v6. This work
adds an auditable, optional path for CoreV4 frequency and context data.

## Source and format

`tools/vocabulary/extract_corev4_contexts.py` checks the existing CoreV4 asset
manifest, decodes each `.atd` in original dictionary index order, and reads its
matching `_0.atc`, `_1.atc`, and `_2.atc` files. It stores each of seven variants
separately in `tools/data/corev4/english/contexts/`. The snapshots retain the
CoreV4 counts, application-context tag, dictionary-local IDs, and any external
global IDs. The original encrypted files remain in `raw/`.

The six format-v2 `_2.atc` tables contain **next-next associations**. They are
preserved as `next_next` and are not relabeled as ordered trigrams. The format-v4
Indian English `_2.atc` contains four ordinary ordered records plus 406,920
static MARISA trie keys. The extractor joins each key with its separate count
vector by MARISA key ID, yielding 406,924 ordered trigram records. The small C++
helper `corev4_marisa_export.cpp` uses CoreV4's own MARISA implementation.

Selected source totals, before mapping into iOSKeyboard:

| Variant | Unigram forms | Bigram records | Ordered trigram records | Next-next records |
| --- | ---: | ---: | ---: | ---: |
| US, older | 47,692 | 3,996 | 0 | 1,375 |
| US, profile | 74,343 | 17,613 | 0 | 11,492 |
| Indian English | 95,359 | 43,229 | 406,924 | 0 |
| Four UK snapshots | 49,048–71,639 each | 3,560–22,565 each | 0 | 915–10,652 each |

All seven exact counts and snapshot checksums are in
`tools/data/corev4/english/contexts/manifest.json`. The Indian unigram counts
sum to 278,450, its bigram records to 582,886, and its ordered trigram records
to 5,767,552. These are CoreV4's stored values, not raw corpus token totals.

## Optional KBLM packs

`tools/vocabulary/build_corev4_model.py` maps one variant by spelling into the
existing 114,283-form union and builds a separate KBLM v6 file. It has two modes:

- `replace`: use that variant's unigram, bigram, and ordered trigram data. Existing
  iOS sentence starters remain as an explicit product fallback.
- `merge`: preserve every existing iOS unigram weight, context total, and
  continuation, then add the variant's context counts. The original CoreV4
  counts remain separately available in the snapshot.

The builder checks every retained unigram and n-gram record against the completed
pack. For Indian English, 13 bigram and 456 trigram records refer to excluded
spellings or nonmatching dictionary IDs and cannot map to the current KBLM
vocabulary. Their source values remain in the snapshot and their omission is
reported beside each optional pack. The four apostrophe-policy exclusions in the
current union remain excluded.

Example commands after building CoreV4's original PAL/Core targets with
`python3 docs/corev4/tools/build_and_smoke.py`:

```sh
python3 tools/vocabulary/build_corev4_marisa_export.py \
  --core-root /Users/meherdeepak/Downloads/CoreV4 \
  --build-root /private/tmp/corev4-onboarding \
  --output /private/tmp/corev4_marisa_export
python3 tools/vocabulary/extract_corev4_contexts.py \
  --core-root /Users/meherdeepak/Downloads/CoreV4 \
  --marisa-helper /private/tmp/corev4_marisa_export
python3 tools/vocabulary/build_corev4_model.py --mode replace \
  --output /private/tmp/corev4-en-IN-experimental.bin
python3 tools/vocabulary/build_corev4_model.py --mode merge \
  --output /private/tmp/corev4-en-IN-merged-experimental.bin
```

The replacement pack was 11,600,298 bytes; the merged pack was 19,764,566
bytes. Both passed full KBLM record parity against their inputs. The merged
pack is below the 20,000,000-byte data-file cap, but substituting it into a
recent 20,144,343-byte Release extension would produce an estimated
24,344,363-byte extension, above the 24,000,000-byte release gate. A fresh
Release build is required for an exact packaged size.

## Full-engine comparison

Both optional packs were loaded through the same current macOS keyboard engine
CLI, with the pack path changed by an environment variable in a temporary copy
of the harness. The 132-case CoreV4/iOS corpus and the existing 3,117-case
validation request set were run in separate processes with identical requests.
The local harness did not run neural scoring or iPhone UI insertion.

| 132 scored cases | Current iOS | Indian replacement | Indian merge |
| --- | ---: | ---: | ---: |
| Top suggestion matches target | 113/130 | 114/130 | 114/130 |
| Ordinary typo auto-correction | 39/40 | 31/40 | 39/40 |
| Severe typo auto-correction | 8/9 | 1/9 | 8/9 |
| Contextual real-word auto-correction | 3/11 | 3/11 | 4/11 |

On the 3,117-case validation set, the merge changed the following outcomes:

| Category | Current correct corrections | Merged correct corrections | Current harmful corrections | Merged harmful corrections |
| --- | ---: | ---: | ---: | ---: |
| Single-error typos (1,000) | 855 | 859 | — | — |
| Multi-error typos (400) | 284 | 286 | — | — |
| Real-word typos (250) | 134 | 136 | — | — |
| Clean known words (1,000) | — | — | 12 | 14 |
| Clean out-of-vocabulary words (349) | — | — | 268 | 263 |
| Clean contractions (100) | — | — | 2 | 2 |

The replacement model causes substantial correction regressions. The merged
model shows a small net gain on this request set, with two additional harmful
replacements of known words. This is an experiment, not evidence that the model
improves general keyboard use. No active pack or keyboard setting was changed.
The decoder has not been compared record by record against live CoreV4 context
queries; that independent check remains necessary before a production import.
The next integration decision needs a separate blend calibrated on development
cases, a reserved validation set, compact release packaging, and device checks.
