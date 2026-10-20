# MARISA experiment results — 19 October 2026

Decision: keep the existing packed trie as the production backend. The opt-in
public-API MARISA prototype preserves fuzzy-search results and shrinks the index,
but fails the search-latency gate. No shipping backend switch was made.

Measured on macOS-26.5.2-arm64-arm-64bit, Release C++20, using the current production KBLM v6
corpus of 114,283 forms. Three independent timing processes; the table reports the
median of each process's statistic, not a pooled percentile. Each process measures
275 full-search calls per backend after a warm-up sweep. See README.md for workload,
setup, reproducibility and scope limits.

| Measurement | Existing packed trie | MARISA prototype |
| --- | ---: | ---: |
| Index storage, bytes | 3,857,854 | 758,292 including ID map |
| Full fuzzy search p50, ms | 0.318 | 5.381 |
| Full fuzzy search p95, ms | 0.602 | 5.841 |
| Exact lookup of all 114,283 words, batch p50 ms | 15.44 | 34.81 |
| Whole-process peak RSS, median bytes | 17,416,192 | 18,153,472 |

MARISA reduces vocabulary-index storage by 80.3%, but this adapter's median
full fuzzy search is 16.9× slower. Its exact-lookup sweep is also slower
than the benchmark's native packed-lookup reference. The adapter shares DP rows and
prunes scoring work, but the public MARISA predictive iterator still decodes keys
beneath pruned prefixes. Packed search can skip those subtrees entirely.

The MARISA file is 301,152 bytes and the explicit corpus-ID map is
457,140 bytes. These are index bytes, not whole pack, app binary or
resident-memory savings. The prototype keeps the original full pack, including
its trie, for metadata/ngrams; its higher RSS is additive and does not measure a
replacement pack. No shipping RAM reduction has been established.

Opening and validating the original pack took a median 3.04 ms.
Mapping MARISA and validating every ID/word correspondence added 23.35 ms.
These are warm filesystem observations, not equivalent replacement-only startup
or cold application launch measurements. Offline MARISA build time in the final
run was 55.3 ms; the index is built ahead of use, not per keystroke.

Validation passed:

- Every vocabulary word round-trips to its original corpus ID, including IDs above
  65,535. The ID map is checked as a permutation and verified against every key.
- 1,013 fuzzy-search parity cases match candidate identity/order, Double costs and
  log frequencies exactly. Cases cover multiple radii, touch offsets, funded and
  unfunded search, transpositions, apostrophes, severe typos, incremental prefixes,
  mismatched touch lengths and empty funding.
- Prefix existence and exact frequency-ranked completion membership/order match
  the experiment's lexical-tie oracle. Shipping heap completion tie ordering and
  Glide parity are not established and are not enabled.
- Cancellation, invalid radius/funding and four malformed/stale ID-map fixtures
  are checked. The full prototype suite passed ASan/UBSan.
- The existing native ASan/UBSan suite passed KBLM v2–v6 parsing, corrupt fixtures,
  mapped seeds, spatial/retained DP and the production corpus. Existing n-gram
  tables, model IDs and mutable personalization code were not modified.

These measurements cover full-search kernels on a Mac, not whole-decoder latency,
retained-session speed or a physical phone. A custom compressed-branch cursor could
change the result; this experiment does not show that every MARISA implementation
must be slower. It shows that this public-API adaptation is unsuitable as a speed
upgrade. A shipping migration should wait for a backend that passes this latency
gate, then establish retained-search, completion/Glide, replacement-pack memory and
device-level parity/performance.

Reproduce with `native/experimental/marisa/run.sh`. Raw timing, memory, storage,
parity and sanitizer outcomes are retained in results/. The corpus SHA-256 is
`f796d93b208eb3a76376d1f6646165ce676a98b093f4c894e2b9426fc1417ec4`.
