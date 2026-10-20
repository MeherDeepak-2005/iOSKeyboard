# CoreV4-inspired iOSKeyboard speed optimization

19 October 2026. The production native search implementation is updated.

The full-engine [17 October laptop comparison](/Users/meherdeepak/Downloads/CoreV4/analysis/laptop-comparison/comparison-report.txt)
supersedes the earlier isolated comparison: CoreV4 won fresh-session latency,
tail latency, CPU and peak RSS on that workload. Its distance manager caches DP
state and reuses prefix work (`v2core/core/source/coreengine/atxdunloplevenschtein.cpp`,
roughly lines 750–875); `NGraphHdlr.cpp` also restricts comparisons using character
n-graph dictionary ranges. The report specifically identified iOS retained-session
setup and backspace rebuilds as expensive. These informed this optimization;
CoreV4's integer cost scale and its more restrictive candidate eligibility were
not copied into iOSKeyboard's weighted decoder.

## Implemented

- In `native/DecoderCore/src/IncrementalSearch.cpp`, compute a 256-byte-label
  substitution-cost table once per appended typed character/tap. Previously every
  seeded DP cell called the geometry/scoring function. Arithmetic and Double
  values are unchanged.
- In `native/DecoderCore/src/PackedLexicon.cpp`, lazily compute the same costs once
  per visited byte label and typed column. This speeds full-trie and broad-recovery
  searches while avoiding work for unvisited labels.
- Reuse the existing three DP buffers for one backspace. They already contain
  columns n, n-1 and n-2, so rotating ownership restores both OSA history columns.
  No extra DP history buffer is allocated. Consecutive deletions, changed prefixes
  and changed surviving tap evidence use the established rebuild path. Tap metadata
  is tracked to ensure that deletion still applies the supplied touch evidence.
- Update the native rollback tests and the Swift façade documentation. Production
  Swift ranking, thresholds, model IDs, vocabulary, n-grams, seed cap, personalization
  and severe-recovery eligibility are unchanged. The Swift reference rebuild path
  remains available for comparison.

## Matched current-pack measurements

Both baseline and optimized complete engines were compiled on this M2 with native
`-Os` and Swift `-Osize`, using the same production 114,283-form KBLM v6 pack and
132-case corpus. This pack differs from the 61,082-form historical laptop report,
so these figures are a matched before/after experiment, not a refreshed CoreV4
head-to-head comparison. There were three separate processes per backend, seven
measured identical requests after three warm-ups per case, seven fresh-session
requests per case, and six append/backspace sequences. Each process issued 2,794
requests. Builds, sanitizer checks and final performance runs did not overlap.
Backend order alternated by trial. The table uses medians of run-level statistics.

| Full-engine metric | Before | Optimized | Improvement |
| --- | ---: | ---: | ---: |
| Fresh session, median of case p50, ms | 7.688 | 3.266 | 2.35× faster |
| Repeated request p50, ms | 0.632 | 0.564 | 10.8% lower |
| Repeated request p95, ms | 7.300 | 3.514 | 51.9% lower |
| Request CPU seconds / 2,794 requests | 18.054 | 5.413 | 70.0% lower |

Backspace p50, median across the three runs:

| Word | Before, ms | Optimized, ms |
| --- | ---: | ---: |
| hello | 0.473 | 0.461 |
| correction | 25.677 | 0.273 |
| coeevitjkn | 31.890 | 1.630 |
| definitely | 1.833 | 1.625 |
| recieve | 2.931 | 2.255 |
| qzvaxon | 11.927 | 0.162 |

All 396 paired case records match exactly in correction, suggestions and candidate
word/source/cost/score arrays; all 18 paired editing records match their final
suggestions and correction. Severe recovery remains unchanged, including
`coeevitjkn` → `correction` with and without sentence context.

## Correctness and limitations

The existing native ASan/UBSan suite passed v2–v6 pack validation, corrupt fixtures,
mapped seeds, retained/spatial search and the production corpus. New tests compare
backspace/retype, consecutive deletes, apostrophes, transpositions and changed taps
against independently rebuilt sessions. A separate public-API MARISA scoring oracle
passed 1,013 exact full-trie parity cases with radii 0/1.6/3.6/7.2, touch/funding
variants, vocabulary IDs and malformed-map checks (`weighted-search-parity.json`).

Initial unrestricted-hash replays are retained in `randomized-hash/`. Corrections
were identical, but existing equal-score alternatives reordered between processes;
four paired case records also differed at a tied shortlist cutoff. Shared candidate
scores/costs were unchanged. For exact before/after evidence comparison, final
benchmark processes set `SWIFT_DETERMINISTIC_HASHING=1` for both binaries. This is
a benchmark-only setting; production hashing and ranking were not changed.

These are complete-engine macOS CLI request timings in n-gram mode, including
asynchronous delivery, not UIKit or physical-iPhone measurements. No trained neural
model was available. Readiness observations improved from 60.7 to
46.2 ms, but three processes/backend are insufficient for a launch
p95 claim. Process peak RSS was 49.48 versus
46.48 MiB in the final runs; the earlier randomized-hash runs moved
in the opposite direction, so no reliable RAM reduction is claimed. The three
large retained DP buffers and seed preparation remain; only compact tap metadata
and a transient substitution table were added. Broad recovery and full-trie
fallbacks still have costs, and CoreV4's measured historical fresh-session lead
is not established as eliminated.

## Reproduction

Raw inputs remain in `../laptop-comparison/corpus.json`. Raw final runs, initial
randomized-hash runs, compiler command, source hashes, sanitizer output and summary
are saved here. `compare-runs.py` fails on any case evidence change. The source
change is retained in `optimization.patch` so the pre-optimization native source
can be reconstructed from this exact optimized snapshot without modifying the
working tree.

```sh
# In /Users/meherdeepak/Downloads/CoreV4
python3 analysis/speed-optimization/build-ios-cli.py
# Creates /tmp/ioskeyboard-speed-build/IOSBench.app.

# Reconstruct baseline native sources into a temporary directory:
mkdir -p /private/tmp/kb-speed-reproduce/native
cp -R /Users/meherdeepak/iOSKeyboard/native/DecoderCore /Users/meherdeepak/iOSKeyboard/native/iOS /private/tmp/kb-speed-reproduce/native/
patch -R -p1 -d /private/tmp/kb-speed-reproduce < analysis/speed-optimization/optimization.patch
python3 analysis/speed-optimization/build-ios-cli.py --native-root /private/tmp/kb-speed-reproduce/native --build-dir /tmp/ioskeyboard-speed-baseline-build
cp -R /tmp/ioskeyboard-speed-baseline-build/IOSBench.app /tmp/ioskeyboard-speed-baseline.app
python3 analysis/speed-optimization/run-replays.py
```

Use fresh temporary destinations for reproduction. Existing generated `.app`
destinations should be moved aside before copying. `native/tests/run.sh` in the
iOSKeyboard repository reruns the sanitizer suite. Pack SHA-256:
`f796d93b208eb3a76376d1f6646165ce676a98b093f4c894e2b9426fc1417ec4`.

Raw experiment directory: `/Users/meherdeepak/Downloads/CoreV4/analysis/speed-optimization/`.
