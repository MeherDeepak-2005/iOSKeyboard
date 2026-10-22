# English n-gram rebuild — 20 October 2026

The bigram/trigram tables in `keyboard/langdata.bin` were counted over 41,502 Tatoeba
CC0 sentences (~571k tokens) plus a small MASC overlay, while unigram frequencies come
from a 705M-token subtitle list. Only 31k of the 114,283 words appeared in any bigram,
and "free" had 277 bigram tokens. Context could not rank corrections ("free reign").

## What changed

- **Corpus.** `tools/build_language_data.py` now counts every Tatoeba English sentence
  (2,039,120, CC BY 2.0 FR, vendored as `tools/data/tatoeba-eng-2026-10-20.tsv.bz2`) plus
  the WikiText-103 raw train split (CC BY-SA 3.0, pinned Hugging Face revision
  `b08601e0…`, fetched to `tools/.cache`). Counting is `tools/ngram_corpus.py`: 95.05M
  in-vocabulary tokens against the final 114,283-form vocabulary, about 60 s and 1.8 GB
  peak RAM. Sentence ends, digits, hyphenated compounds, dashes, parentheses and quotes
  are hard boundaries ("an all-star" does not count "an all"). The MASC overlay and
  cold-start priors are unchanged. `--legacy-ngrams` reproduces the previous pack byte
  for byte. Builds are deterministic.
- **Pruning.** Bigrams with count >= 4 (top 1,024 per context) and trigrams with count >= 8
  (top 64 per context). Context totals are pre-pruning. The per-context cap keeps the
  largest scored row (1,025) below the previous pack's largest (8,003), so scoring cost
  per request does not grow.
- **Backoff fix (C++, Swift reference, Python harness).** Witten–Bell assigned a pruned
  context's unretained mass to nothing: escape was `n(1-w)` with `n` the true total but
  counts only for retained rows. It is now `n - w * retained`, which is identical when
  nothing was pruned. The shipped pack already had 1,777 such bigram contexts (15.3% of
  bigram mass, from MASC totals). With the new pruning it affected almost every context:
  before the fix "and the areas" scored -27.6 against -11.2 with no context, and false
  real-word corrections nearly doubled.
- **Budgets.** Pack cap 32 MB (`LARGE_LANGDATA_CAP`); `verify_release_artifacts.py
  --large-ngrams` gates 32 MB pack / 38 MB non-neural extension.

| Pack | Bigram contexts / entries / tokens | Trigram contexts / entries | Words in a bigram | Bytes |
| --- | ---: | ---: | ---: | ---: |
| Previous (`f796d93b…`) | 29,206 / 241,198 / 650k | 218,403 / 386,447 | 31,168 | 15,564,546 |
| New (`9db07606…`) | 55,520 / 1,280,074 / 64.7M | 266,840 / 767,271 | 58,184 | 28,311,910 |

## Quality (held-out, not used for counting)

7,078 MASC held-out sentences (document-family split). Each in-vocabulary word was
decoded as typed (false-correction check) and with one synthetic slip, using its
two preceding words as context. Engine set up as in the shared-engine host replay.

| Metric | Previous pack | New pack + fix |
| --- | ---: | ---: |
| Correct words wrongly corrected (61,361) | 1.26% | 1.16% |
| Slips autocorrected to the intended word (34,316) | 83.71% | 85.34% |
| — neighbor / transpose / deletion / insertion | 84.6 / 83.9 / 71.9 / 87.5% | 85.9 / 85.9 / 74.6 / 89.6% |
| Intended word in top 3 | 96.97% | 97.23% |
| Next-word top 3, nothing typed (55,997) | 21.96% | 25.82% |
| Perplexity | 1,202 | 742 |
| 132-case corpus, committed = target / in top 3 | 118 / 122 | 118 / 123 |

The new pack without the backoff fix had 2.21% false corrections and perplexity 3,709;
do not ship one without the other. Behavior change: after "free", slips such as
`reogn`, `riegn`, `reing` now commit **rein** (74 corpus counts; "free reign" occurs
fewer than 4 times and is pruned), and a typed "free reign" itself corrects to "free
rein". 16 of 132 shared-engine decode goldens changed; all 60 Glide goldens are unchanged.

## Cost

Matched macOS full-engine benchmark (same harness as the shared-engine checkpoint,
3 alternating processes, each build with its own pack): request p50 0.160 → 0.156 ms,
p95 1.630 → 1.654 ms, fresh session 1.695 → 1.720 ms, CPU 3.12 → 3.10 s, Glide flat.
Readiness median 21.9 → 27.2 ms. End physical footprint 25.25 → 24.94 MiB; peak RSS
47.6 → 59.5 MiB from read-only mapped pack pages. Release extension 33,011,638 bytes.
Not measured on a physical iPhone or Android device.

## Validation

Portable ASan/UBSan suite and 4/4 CTest (including the golden replay), 134/134 simulator
tests in 8 suites, Android `EngineReplayTest` 5/5 on the API 36 emulator,
`tools/vocabulary/verify_corev4_import.py`, Release arm64 build and the size gate.
Raw benchmark runs: `/Users/meherdeepak/Downloads/CoreV4/analysis/shared-engine-final-2026-10-20/ngram-pack/`.

## Review pass — 21 October 2026

Fixes (each with a regression test where it is testable host-side):

- **Stale touch evidence in retained search.** After a backspace below five letters,
  retyping the same letters with different touches reused DP columns computed from the
  old touches. `IncrementalSearch` and the Swift reference now rebuild when any
  surviving prefix tap differs.
- **Glide invalidation was silent.** `updateGlide` returned an empty list when the stream
  could not be extended (path shrank, pitch changed), so iOS committed the stale preview
  instead of the full-path fallback. It now throws `GlideInvalidated`. iOS already maps
  that error to `session.invalid`; Android reports `STATUS_GLIDE_INVALIDATED` (4) and no
  longer overwrites the last good Glide result with a cancelled one.
- **Personalization export/import asymmetry (Android).** Learning accepted empty or
  over-long words and context keys that `decodePersonalization` rejects, so one such
  event made every later import fail. Writes now enforce the decoder's limits.
- **Negative backoff mass on malformed rows.** Retained counts are clamped to the stored
  total (C++ and Swift). The builder also refuses totals above `u32`.
- `nativeCancel` racing `close` no longer throws.

Performance, all with identical outputs (396/396 paired case records, editing and Glide):

- Continuation IDs are validated when rows are read rather than by a whole-pack scan at
  load. That scan faulted in 25.7 of 27.0 MiB; load now touches 10.1 MiB.
- Language-model scoring scans each context row once and keeps counts only for the scored
  words, instead of building a row-sized hash map: 52 → 15 µs per call.
- Input that the retained search rejects (digits, hyphens, non-ASCII) no longer rebuilds a
  ~24k-seed set on every keystroke.
- The Swift side releases the cached personal-count snapshot before learning, so native
  copy-on-write no longer deep-copies the model on every committed word. Lexicon boosts
  are converted once per change rather than on every `logFreq` call, and Glide dynamic
  words are computed once per gesture.

Matched benchmark, pre- vs post-review on the same pack: request p50 0.159 → 0.128 ms,
p99 2.60 → 2.10 ms, contextual fresh session 0.652 → 0.537 ms, CPU 3.12 → 2.98 s,
readiness 27.3 → 21.1 ms, peak RSS 59.4 → 39.9 MiB, end footprint 24.8 → 19.8 MiB.
Gates: ASan/UBSan suite, 4/4 CTest, 134/134 simulator tests, Android 5/5.

Not changed: a fresh word session still spends about 2.7 ms advancing about 18k retained
seeds over the first five letters. That DP is the largest remaining per-word cost. Making
it smaller needs an algorithmic change, such as a cutoff on the column minimum, and a
parity plan.
