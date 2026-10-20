# Witten–Bell startup optimization — 20 October 2026

Implemented a measured startup improvement in the current restored-Witten–Bell
engine. Fresh-engine prediction readiness fell from 52.69 to
37.32 ms in the final Mac comparison (29.2% lower median).
Steady-state typing throughput is essentially unchanged. No smoothing, ranking,
corpus, search radius, candidate cap, model ID or personalization behavior changed.

## Production change

`keyboard/Engine/LangData.swift`, `buildAnchorIndex()`, now reads printable-ASCII
word endpoints directly from one view of the mapped bytes. Previously the index
constructed a Swift String for every dictionary form and asked for its grapheme
count and first/last Character, including all 114,283 forms during engine startup.
Printable ASCII can use byte length/endpoints with the same result. Unicode and
control bytes retain the original String/Character path, including combining marks
and CR/LF. IDs, frequency ordering, bucket contents and caps are preserved.

The index remains eagerly prepared during the same initialization phase. Work was
not moved onto the first swipe or deferred past the first prediction. There are
no new caches, background queues, dependencies or data files in the final change.

## Matched full-engine measurements

Same Mac and production KBLM v6 corpus; C++ `-Os` / Swift `-Osize`, n-gram mode,
132-case intent corpus, seven measured identical requests after three warm-ups,
seven fresh sessions per case, and six append/backspace sequences. Three separate
processes per version, with alternating version order. Each process issues 2,794
requests. Both snapshots contain the same restored Witten–Bell implementation;
the only final production source difference is the anchor-index function.
Builds and simulator tests finished before the timing runs. The benchmark alone
sets `SWIFT_DETERMINISTIC_HASHING=1` to compare tied prediction evidence exactly.

The table uses medians of run-level statistics, except startup: ten additional
fresh processes per version, alternating order, with a warm filesystem cache.
Readiness measures engine construction/queued initialization through the first
prediction delivered, excluding executable loader startup and keyboard UI drawing.
It is paid when a new engine is initialized, not on each word or empty context.
Startup p95 uses nearest rank and therefore equals the largest of ten samples;
these are small-sample observations, not an iPhone launch guarantee.

| Metric | Restored WB baseline | Optimized WB |
| --- | ---: | ---: |
| Fresh-engine prediction readiness median, ms | 52.688 | 37.319 |
| Fresh-engine prediction readiness p95, ms | 55.637 | 39.378 |
| Repeated request p50, ms | 0.560 | 0.600 |
| Repeated request p95, ms | 3.528 | 3.447 |
| Repeated request p99, ms | 4.268 | 4.598 |
| Fresh-session median of case p50, ms | 3.138 | 3.091 |
| Contextual fresh-session median of case p50, ms | 2.515 | 2.418 |
| Request CPU seconds / 2,794 requests | 5.191 | 5.239 |
| Process peak RSS, MiB | 46.94 | 46.77 |
| End physical footprint, MiB | 24.52 | 26.98 |

The typing/CPU differences are small and mixed, so no typing throughput or resident
memory improvement is claimed. This optimization addresses startup. The three-run
full-workload readiness observations were 45.87 versus
35.31 ms; the ten separate readiness trials provide the
primary startup figures above.

Glide was checked separately over 60 deterministic clean/noisy paths, five measured
requests after three warm-ups per case:

| Glide | Baseline | Optimized |
| --- | ---: | ---: |
| p50, ms | 5.358 | 4.503 |
| p95, ms | 6.470 | 6.255 |

This is one Glide process per version; the figures are supplementary, not a
replicated Glide speed claim. The workload does not measure trained neural models,
UIKit insertion/drawing, physical-iPhone thermals, battery or long-term user history.

## Validation

- All 396 paired case records match suggestions, correction decisions and complete
  candidate word/source/cost/score arrays exactly.
- All 18 paired editing records match their suggestions/correction.
- All 60 Glide cases return identical suggestion lists.
- The final six-test NativePackedLexiconTests suite passed on the iPhone 17 Pro
  simulator, including exhaustive corpus reads, every original anchor bucket,
  repeated warming, corrupt backing, wide IDs and Unicode/control endpoint fixtures.
- The test fixture compares CR/LF endpoints with the original Character operations;
  it does not assume that byte endpoints equal Swift Character endpoints.
- The source/corpus SHA-256 manifests, compiler command, raw replays and results are
  saved beside this report. Source is frozen for before/after compilation. The
  optimized LangData.swift still matches the working tree. Concurrent native
  migration changed PackedLexicon.hpp, PackedLexicon.cpp and KBDecoderBridge.h
  after the snapshots; those later changes are excluded from both measurements.
  The combined migration needs its own benchmark after it stabilizes.

## Rejected scorer-cache experiment

A bounded, locked cache of prepared immutable context rows and direct score-batch
assembly also passed the 12-test scoring suite, including learning updates,
eviction, reattachment and concurrent calls. However, it did not yield a meaningful
end-to-end typing/CPU improvement in this workload. Those scorer changes and their
additional cache-only test were removed. NgramScorer.swift is byte-identical to the
pre-task restored-WB snapshot. The experiment's raw runs, source patch and manifests
remain in `context-cache-experiment/`; their combined prototype results are not the
final production results above.

## Reproduction and artifacts

From `/Users/meherdeepak/Downloads/CoreV4`:

```sh
python3 analysis/wb-optimization-2026-10-20/build-ios-cli.py
python3 analysis/wb-optimization-2026-10-20/after-build-ios-cli.py
python3 analysis/wb-optimization-2026-10-20/run-benchmarks.py
```

The builders use the frozen `/private/tmp/kb-wb-before-20261020` and
`/private/tmp/kb-wb-after-20261020` trees. They produce standalone `.app` bundles
under the corresponding `kb-wb-*-build-20261020` directories. The final
`optimization.patch` reconstructs the source difference; manifests identify the
exact snapshot and binary hashes. The runner checks the unchanged corpus hash
before each full/startup replay and fails on any case/editing/Glide evidence change.

Simulator commands and outcomes are in `scoring-tests.log` (rejected prototype)
and `anchor-suite-final.log` (final index change). An earlier method-filtered test
invocation selected zero Swift Testing cases; the final suite invocation actually
executed all six tests. Earlier fixture logs are retained for provenance.

The corpus hash is `f796d93b208eb3a76376d1f6646165ce676a98b093f4c894e2b9426fc1417ec4`.
The historical 193 ms MKN readiness figure is not the baseline for this improvement;
this experiment compares two restored-WB engines on the current pack.

Raw artifacts: `/Users/meherdeepak/Downloads/CoreV4/analysis/wb-optimization-2026-10-20/`.
