# English expansion implementation results

Date: 6 October 2026. Scope: the checked-out English pack, not the deployed App Store binary.

The open-source expansion is integrated into `keyboard/langdata.bin`. The existing Swift/iOS and C++ readers consume the same KBLM v5 pack; no engine thresholds, neural models, binary format or Telugu resources were changed. Larger optional corpora remain deferred as listed below.

| Measure | Before | Integrated |
|---|---:|---:|
| Surface forms | 60,450 | 61,082 |
| Pack bytes | 9,391,297 | 9,455,641 |
| Bigram entries | 239,287 | 241,198 |
| Trigram entries | 384,691 | 386,447 |
| Hand-selected probe membership | 239/478 | 454/478 |
| MASC held-out supported-token membership | 97.011% | 97.027% |

All 60,450 baseline forms and their unigram frequencies are preserved. Every baseline n-gram record retains at least its previous count. Additional records total 1,911 bigrams and 1,756 trigrams. Word IDs are rebuilt consistently across all tables, and the pack remains frequency ordered. The additional storage is 64,344 bytes (0.69%); mapped file size does not equal resident RAM.

## Coverage interpretation

The targeted probes were used to motivate curated additions, so their improvement is an admission diagnostic, **not an independent recall measurement**. MASC held-out documents provide an independent lexical check: 10 additional supported tokens out of 65,244 are recognized. The corpus is mainly American English and predates many modern terms, so this small gain does not measure international texting quality. An additional 2,323 unsupported spans remain outside the ASCII token calculation.

| Category | Present before | Present after | Total |
|---|---:|---:|---:|
| common controls | 33 | 33 | 33 |
| everyday inflections | 12 | 44 | 44 |
| formal academic | 36 | 57 | 58 |
| international english | 21 | 41 | 44 |
| international names places | 28 | 45 | 45 |
| literary | 21 | 29 | 30 |
| modern technical | 15 | 52 | 52 |
| orthography and contractions | 30 | 30 | 43 |
| regional spelling | 5 | 54 | 55 |
| texting and slang | 40 | 71 | 76 |

All tested modern technical forms, everyday inflections and international names now have exact vocabulary entries. Examples include `colour`, `organise`, `favourite`, `reproducibility`, `epistemology`, `unsubscribed`, `screenshots`, `livestreaming`, `brb`, `ttyl`, `tysm`, `passkeys` and `Bengaluru` (stored lowercased, as in the existing English path).

Remaining probe gaps include accented/hyphenated/digit-bearing forms, single-letter texting shortcuts, `prioritised`, `buka`, `matric` and `updation`. Those are not silently transliterated or admitted without the selected evidence. Recognition-only versus automatic-correction eligibility and locale-aware preferences remain future decoder work.

## Sources actually integrated

| Source | Selection and role |
|---|---|
| [ESDB pinned v2](https://github.com/en-wl/wordlist/tree/1e5b7d3a72f47a71da5d28686c1dd4b397178485) | US, British -ise/-ize, Canadian and Australian size-60/70 forms; source spelling validity plus frequency/dispersion gates. 465 additions have ESDB evidence. |
| [Open English WordNet 2025 core](https://en-word.net/) | Single ASCII lemma/form validity and POS; stronger usage gate for WordNet-only forms. 371 additions have WordNet evidence, overlapping ESDB/project. No definitions are bundled. |
| [MASC text-only corpus](https://anc.org/data/masc/) | 390 source documents; 41,374 deduplicated training sentences and 7,078 held-out sentences. Training counts/dispersion help admission; repeated n-gram records improve context tables. |
| [FrequencyWords 2018](https://github.com/hermitdave/FrequencyWords) | Existing pinned unigram baseline remains unchanged; independent occurrence counts support new admission. New priors are capped separately from actual observed counts. |
| Project-authored vocabulary/examples | 167 explicit additions and weak authored context priors, covering gaps not supported by older corpora. Not native-speaker certified or empirical counts. |

[All admitted additions](ADDED_WORDS.md) are listed with their priors and sources. Source contribution counts overlap and must not be summed. The admission ceiling was 4,000 additions; only 632 passed the implemented rules. No bulk padding was used. MASC sources are split by document family before training; author-disjoint isolation cannot be claimed from the text-only archive.

Licenses, upstream notices and modifications are preserved in the source manifest, `THIRD_PARTY_NOTICES.md` and the bundled `keyboard/ThirdPartyNotices.txt`. Adapted FrequencyWords-derived dictionary data remains under CC BY-SA 4.0. MASC text snapshots are evaluation/build inputs outside the keyboard resource directory.

## Verification

- Python admission, boundaries, split, denominator, malformed-input and cleanup regression checks: 12 passed.
- Pre-expansion builder reproduces the original pack hash exactly.
- Source preparation rerun: identical manifest and snapshot hashes.
- Expanded pack rebuilt twice with identical bytes and SHA-256.
- Structural comparison verifies baseline forms/weights, all previous n-grams, valid IDs, denominators and release-size cap.
- Final size-budgeted pack, iOS Release simulator validation: 100 tests passed (90 keyboard regressions and 10 native/parity/severe tests).
- Newly admitted literal words remain suggestions without destructive correction; expanded forms are available through trie completions and Glide anchors.
- `coeevitjkn → correction`: 155/155 correct commits across all five contexts; trained neural scorer unavailable.
- Built app dictionary and notices match the source files exactly.

Integrated pack SHA-256: `ddbb25cb14d90bfb3e0097980aab68b8423f9e768b9bdfb8fbdbd55f163298d2`.

The first Release test command exposed existing `@testable` imports requiring `ENABLE_TESTABILITY=YES`; the validation rerun enables this only on the command line. Production build settings are unchanged.

## Reproduction, cleanup and remaining scope

Commands and selection policy: [pipeline README](../../tools/vocabulary/README.md). Comparison evidence: [validation JSON](expansion-validation.json), [historical baseline audit](coverage-audit-2026-10-06.json), [expanded audit](coverage-audit-after-expansion.json).

COCA/GloWbE, NUS SMS and BNC2014 are excluded because suitable embedded commercial terms are unresolved or restricted. Kaikki, wordfreq, Gutenberg, PMC and GeoNames need separate adapters and source-specific filtering; this release does not claim they were imported.

Trained model/tokenizer artifacts are unavailable on this laptop. Neural scorer quality, real international conversation recall, physical iPhone latency/RAM, locale balancing and native-speaker review remain unverified. A larger dictionary alone does not establish better correction decisions or tone awareness.

Cleanup completed: source archives, extracted upstream/database files, candidate/baseline packs, Xcode derived data, result bundles and temporary logs from this run were removed (920,357,582 bytes). Small reproducible snapshots, provenance, scripts and exported test evidence remain. The standard FrequencyWords builder cache is retained for rebuilding; unrelated files and pre-existing changes were preserved.

## Severe-typo replay timings

Release iPhone 17 Pro simulator, iOS 26.5; n-gram mode, no touch offsets. These are current replay timings, not paired physical-device speed improvements.

| Context | Correct commits | Warm p50 ms | Warm p95 ms |
|---|---:|---:|---:|
| empty | 31/31 | 11.70 | 70.80 |
| auto | 31/31 | 10.10 | 19.83 |
| possibly / receive | 31/31 | 17.13 | 53.19 |
| for / definitely / decided | 31/31 | 16.10 | 22.28 |
| could / definitely / receive | 31/31 | 10.12 | 14.76 |

[Before benchmark](coeevitjkn-before-expansion.json) and [after benchmark](coeevitjkn-after-expansion.json) retain full candidate evidence. Historical timing differences are not controlled measurements.

## Complete extension size budget

The initial unsigned iPhone Release bundle exceeded the 14,000,000-byte cap by
13,862 bytes. MASC's minimum retained n-gram occurrence count was raised from
three to five; all baseline records and all 632 additional vocabulary forms remain.
Context denominators retain their actual pre-pruning totals. This reduces the
expansion from 106,200 to 64,344 additional bytes. The final unsigned arm64 iPhone Release build succeeds and its full extension
is **13,972,006 / 14,000,000 bytes**. The size gate passes with 27,994 bytes
of unsigned headroom. The distribution-signed archive should be checked with the
same verifier before release. See [device-target bundle audit](device-release-bundle-audit.json).

Universal simulator code contains both arm64 and x86_64 and must not be presented
as the shipping iPhone size. The device build is arm64, unsigned, and cross-compiled;
it does not measure physical iPhone latency or RAM.

Final Xcode evidence: [100-test result summary](simulator-test-results.json), [verification summary](test-summary.json), [pack/bundle equality](bundle-validation.json).
