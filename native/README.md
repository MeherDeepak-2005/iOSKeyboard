# CoreV4 vocabulary integration (2026-10-19)

The active English pack is KBLM v6 with 114,283 stored forms. Both native and
Swift readers support it; older v2–v5 packs remain readable. V6 retains sorted
context arrays and binary search, with 32-bit word IDs. Bigram contexts are
`(id,total,start,count)` (16 bytes), trigram contexts are
`(firstID,secondID,total,start,count)` (20 bytes), continuations/starters are
`(id,count)` (8 bytes), and trie nodes are `(u8 label,u8 childCount,u32 firstChild,
u32 wordID,u32 maxFreq)` (14 bytes). Trie nonterminals use `0xffffffff`.
The 36-byte header, frequencies, offsets, and UTF-8 blob follow v5's layout.
Trigram sorting compares `(uint64_t(firstID)<<32)|secondID`; IDs never use
v5's 16-bit pair packing. See `docs/corev4-import/IMPORT-RESULTS.txt` for
admission policy, source assets, rebuilds, validation and limits. Historical
measurements below predate this integration.

# Current native default

The English core is now primary for packed fuzzy traversal, retained search,
frequency-boost preparation, spatial channel costs and batched language-score math.
iOS uses Objective-C++ transport; Android Kotlin/JNI integration files share the
same neutral C++20 library and generated dictionary. Normal shipping Release
excludes the large Swift search references; Debug/test builds keep them for parity.

See [current architecture and remaining migration work](../ANDROID_IOS_ARCHITECTURE.md)
and [verification](../docs/decoder-platform/VERIFICATION.md). The historical
checkpoint sections below describe the opt-in state **before this promotion**.
They are retained as measurements, not claims about the current whole decoder.

# DecoderCore migration progress

This directory contains the first three stage-2 implementation slices. Production decoding still uses Swift. Packed reads, spatial channel costs, retained DP and immutable mapped seed preparation now have native implementations behind internal opt-in seams. Packed/mutable trie traversal, n-gram scoring, ranking, Glide and neural inference remain to migrate.

## Implemented

- `DecoderCore/include/PackedLexicon.hpp` and `src/PackedLexicon.cpp`: portable C++20 immutable reader for KBLM v2–v5, checked binary section/offset/ID/range validation, words/frequencies, starter IDs and bigram/trigram continuations. Legacy probing is bounded; v5 uses the existing sorted context tables. True context totals and stored continuation ordering are preserved.
- `iOS/KBDecoderBridge.h/.mm`: Objective-C++ ownership/transport for the reader. Retains an immutable NSData backing; no corpus copy is made in C++. Native exceptions become NSError. Missing n-gram contexts remain optional results, distinct from failures. Returned arrays own their data. The generic NSObject initializer argument deliberately avoids Swift's automatic NSData→Data import conversion; the bridge checks that the supplied backing really is immutable NSData.
- `LangData(url:compareNativeReads:)`: explicit internal comparison flag, default false. The comparison path maps one immutable NSData backing and supplies it to both native and Swift readers with `Data(referencing:)`. Normal decode/search methods still return Swift results.
- `LangData.verifyNativeReadParity()`: offline exhaustive comparison of words/frequencies, starters at multiple caps, all bigram IDs, and all stored trigram contexts with unrestricted and capped continuations. It checks backing pointer identity. It creates temporary audit arrays; this is a validation tool, not an interactive benchmark or a production callback design.
- `DecoderCore/include/SpatialModel.hpp` and `src/SpatialModel.cpp`: Double QWERTY geometry/substitution costs and existing first-letter penalties. No thresholds/layout constants change. Swift still owns tap-profile persistence and its statistical adaptation until a later slice.
- `DecoderCore/include/IncrementalSearch.hpp` and `src/IncrementalSearch.cpp`: retained OSA DP columns, transposition, apostrophe deletion discount, append/edit/backspace rebuild and seed-order candidate emission. Consumes normalized English bytes; invalid/empty requests leave retained state unchanged, matching Swift. Comparison instances own bounded seed snapshots and DP buffers; this duplication is intentionally limited to comparison mode, not a second vocabulary corpus.
- `KBIncrementalSearch`/`KBSpatialAudit` in the bridge: whole seed batches and numeric touch buffers, native error translation, owned channel candidates. Numeric inputs are consumed synchronously with unaligned-safe reads. Native sessions remain confined to their façade's execution lane.
- `IncrementalDecodeSession(seeds:compareNativeSearch:)`: optional shadow execution and exact candidate-coverage/order checks plus `1e-9` Double evidence tolerance. Defaults false and always returns Swift results. Audit failures are retained in `nativeParityFailure`, not silently accepted. `NativeDecoderParity.swift` handles Swift touch-buffer conversion and comparison only.
- `PackedLexicon.incrementalSeeds` / `IncrementalSeedSet` / `KBIncrementalSeedSet`: native root gating, vocabulary-ID-ordered selection, cap fallback, log-frequency calculation and shared immutable offsets. Seed spellings/labels borrow the one retained vocabulary backing instead of materializing Swift strings/bytes or per-seed Foundation transport. `KBIncrementalSearch(seedSet:)` retains the seed set and its reader/backing, creates only session-local DP state, and supports independent sessions sharing preparation. The owning seed-array constructor remains for dynamic/parity inputs. Both seed sets and sessions explicitly default destruction and delete copy/move operations; owning pointers can be transferred. This protects internal views and prevents accidental buffer copies.
- `LangData.nativeIncrementalSeeds`: opt-in mapped-reader boundary for the new path; requires `compareNativeReads: true`. It is a static-vocabulary seam. `Lexicon.makeIncrementalDecodeSession` still uses Swift and applies its existing personalization boosts; those boosts need a native immutable snapshot before production can route to mapped native seeds. No production switch or cache keyed only by first letter was introduced.
- Explicit Xcode source membership and bridging header for both app and keyboard extension. No C++ containers are exposed to controller code.

## Verification commands

From the repository root:

```sh
native/tests/run.sh
xcodebuild -project keyboard.xcodeproj -scheme keyboard -configuration Debug \
  -destination 'platform=iOS Simulator,id=<available-device-id>' \
  -derivedDataPath /tmp/ioskeyboard-native-derived CODE_SIGNING_ALLOWED=NO \
  test -only-testing:keyboardTests
```

For optimized parity, run the same Xcode command with `-configuration Release ENABLE_TESTABILITY=YES` and select `NativePackedLexiconTests` / `NativeSearchParityTests`. Testability is a command-line validation override; production Release settings are unchanged.

The portable runner uses ASan/UBSan, warnings as errors, v2–v5 fixtures, every truncated fixture prefix, corrupt fields, limits/absent contexts and completely full legacy hash lookup. It also validates/reads the actual English corpus. Swift tests compare native reads with existing Swift reads and exercise bridge errors/ownership/default opt-out.

## Verified checkpoints (2026-10-06)

- Portable ASan/UBSan tests pass for v2–v5 binary formats and spatial/retained DP goldens, including `coeevitjkn` → `correction` channel cost `6.525`.
- Exhaustive native/Swift packed-read parity passes for 60,450 words, every word ID as a bigram query, and all 217,418 stored trigram contexts; the same backing address is verified.
- Spatial parity passes for all 65,536 discrete byte pairs, continuous touch cases (including missing/nonfinite taps) and first-letter policy lengths 0–12.
- Retained DP parity passes for 9,228 production seeds, append/edit/backspace sequences, contractions, severe typos, optional/mismatched taps, normalized/invalid inputs and empty seed sets.
- All seven native parity tests pass in optimized Release on the simulator (`ENABLE_TESTABILITY=YES` for this validation command only). The normal shipping Release build also passes for app and extension, without that override.
- All 96 Debug simulator tests pass. The existing five-context severe-typo benchmark again passes 155/155 replays. The saved prior Release benchmark JSON is preserved; concurrent Debug suite timings are not substituted for that performance baseline.
- The Mac Glide evaluation harness compiles/links the production sources and bridge (`tools/glide_eval/run.sh --build-only`).

## Measured performance checkpoint (2026-10-06)

Measured on an Apple M2 Mac with 8 GiB RAM. The primary latency table uses an isolated optimized iOS simulator benchmark (101 samples/backend, three warm-ups, alternating backend order), 9,228 actual English seeds and `coeevitjkn`. Timed native operations include bridge input work and candidate conversion to Swift where applicable; shadow auditing is disabled. Coverage/order/cost parity is checked outside the timer. Compilation and final benchmark runs were performed sequentially. These are retained-DP measurements, **not whole-decoder latency or physical-iPhone results**; no trained neural scorer is involved.

| Operation | Swift p50 / p95 (ms) | C++ through bridge p50 / p95 (ms) | Median speedup |
| --- | --- | --- | --- |
| Session creation only | 0.524 / 0.579 | 5.393 / 6.110 | 0.10× |
| Creation + full-word DP + candidates | 27.878 / 29.823 | 20.333 / 21.316 | 1.37× |
| Retained one-byte append | 2.742 / 2.977 | 1.746 / 1.889 | 1.57× |
| Retained append with tap offset | 2.871 / 3.058 | 1.713 / 1.834 | 1.68× |
| Candidate materialization | 0.034 / 0.046 | 0.029 / 0.046 | 1.17× |
| Full-word DP + candidates (creation excluded) | 26.776 / 27.592 | 14.402 / 15.137 | 1.86× |
| Backspace rebuild + candidates | 24.354 / 25.706 | 12.896 / 13.501 | 1.89× |

The initial boxed DP path benefited, including a **27% lower median** for creation plus full-word DP in this workload. Session creation alone was about **10× slower**, so setup could offset the benefit on short words. That bridge serialized/boxed every seed and C++ copied the seed snapshot; this experiment did not isolate their individual shares. The mapped-seed checkpoint below addresses these costs. Do not multiply a kernel speedup into a claim about whole-keyboard latency.

Memory uses five separate optimized macOS process runs per backend on matched seed/word input, not the simulator app. Median peak RSS: **Swift 10.58 MiB, native 13.09 MiB**, a **2.52 MiB increase**. These values include process/runtime overhead and initialization transients; they are neither steady-state decoder heap nor an iPhone extension budget. Both implementations have exactly **1,949,784 bytes (1.86 MiB)** in their three Double DP buffers for 81,241 cells. No RAM saving is established. The vocabulary file remains **9,391,297 bytes**; there is no vocabulary/model storage reduction in this migration slice. Added native executable code is not a storage optimization.

Physical-device validation remains pending: the known iPhone 13 and XR were unavailable when checked. Production decoding remains Swift, so these kernel results are potential benefits of future native routing, not improvements already applied to the shipped decode path. The final native parity benchmark passed on the simulator; prior severe-typo/quality results are unchanged.

Reproduce Mac timings and peak RSS with `tools/native_benchmark/run.sh`, then summarize with `python3 tools/native_benchmark/summarize.py`. The Darwin `time -l` profiler needs access to kernel timing metadata. The simulator test is opt-in through `/tmp/ioskeyboard-native-perf-config.json` (`iterations` and absolute `output` fields) and run alone as `keyboardTests/NativePerformanceBenchmark` in Release with `ENABLE_TESTABILITY=YES`. Remove the config afterward so normal regression runs do not measure performance under concurrent tests. The shared harness is `keyboardTests/NativePerformanceBenchmark.swift`.

Raw [Mac timings](../tools/evaluation/results/native-performance/macos-kernels.json), [simulator timings](../tools/evaluation/results/native-performance/simulator-kernels.json) and [summary including memory samples](../tools/evaluation/results/native-performance/summary.json) are retained. The earlier `coeevitjkn-simulator.json` remains unchanged.

## Mapped-seed initialization checkpoint (2026-10-06)

Moved root selection, word/frequency reads, log-frequency calculation and offset preparation into the C++ reader. A reusable immutable seed set references the existing mapped vocabulary bytes. Sessions share those descriptors and allocate only their own DP buffers; no Swift seed arrays, per-seed Foundation boxing or C++ string copies are needed on this path. The selected roots, cap fallback, vocabulary-ID order and costs are unchanged. The existing owning/boxed constructor remains available for parity and dynamic inputs.

Paired Release simulator measurements on the same M2 Mac, 101 samples/backend after three warm-ups, alternating backend order, 9,228 static English seeds and `coeevitjkn`. Candidate conversion back into Swift is timed where applicable. There is no shadow execution in timers; native evidence parity and destruction are outside them. Per-sample autorelease pools keep temporary Foundation objects from accumulating across the run. Mac timing runs use 51 samples/backend. Runs were sequential, with no simultaneous compilation, tests or other benchmark run.

| Operation | Swift p50 / p95 (ms) | Boxed C++ p50 / p95 (ms) | Mapped C++ p50 / p95 (ms) |
| --- | --- | --- | --- |
| Seed preparation only | 2.184 / 2.500 | — | 0.740 / 0.797 |
| Session creation from prepared seeds | 0.508 / 0.631 | 5.131 / 6.278 | 0.193 / 0.225 |
| Seed selection + session creation | 2.608 / 2.801 | 7.267 / 7.936 | 0.900 / 1.068 |
| Seed selection + creation + full-word DP + candidates | 27.768 / 29.984 | 22.234 / 24.609 | 15.737 / 20.901 |
| Resource opening and validation, cached filesystem | 0.131 / 0.214 | — | 5.507 / 5.656 |

Prepared native session creation is **26.6× faster than the boxed native path** and **2.64× faster than Swift** in the paired initialization run. Including seed selection, setup is **65.5% lower than Swift**. Including seed selection, creation, full-word DP and candidates, the median is **43.3% lower than Swift**. The separately retained kernel run also verifies append/backspace evidence and timings using the new seed set.

Resource opening remains more expensive natively: the C++ reader validates every packed section, ID/range and trie node, while the existing Swift constructor checks the header and section bounds. This row measures different validation work and cached filesystem access; it is not a cold-launch or physical-device measurement. Reader validation happens once per reader opening, not at every seed-set/session creation. No validation was removed to produce the setup gains.

The updated memory comparison retains the vocabulary through each session in **all three backends**. Five isolated optimized Mac processes/backend report median peak RSS of **Swift 10.55 MiB**, **boxed native 13.45 MiB**, and **mapped native 19.14 MiB**. The mapped path is **8.59 MiB above Swift**, so faster setup does not establish a RAM saving. These are total process peaks, including runtime, initialization transients and resident vocabulary pages. Native opening validates sections that the Swift constructor does not traverse; individual contributions and steady-state heap have not been profiled. Both paths still allocate 1,949,784 bytes in three Double DP buffers. Vocabulary/model storage is unchanged. The earlier standalone snapshot RSS test above used a different vocabulary lifetime; use this updated experiment for the mapped-session comparison, and a physical phone for an extension RAM budget.

All nine native Release parity tests pass. New tests compare all 26 initial letters with missing, finite, infinite and NaN touches, production cap fallback and expanded coverage, caps at/below the selected count, log frequencies, independent sessions and backing lifetime after Swift reader/seed-set handles are released. ASan/UBSan tests cover mapped seed fixtures in v2–v5, borrowed byte identity, valid empty sets, cap overflow, empty-word fallback and shared-session state. The five-context production severe-typo regression still passes 155/155 replays; the previous saved result is preserved. Trained neural artifacts remain unavailable.

This path covers static vocabulary. Personalization boosts, mutable/adopted vocabulary integration, revision routing and whole-decoder/native selection remain to migrate before production can use it. Production still uses Swift. The setup and DP timings do not establish whole-keyboard or iPhone improvements.

Raw [simulator initialization](../tools/evaluation/results/native-initialization/simulator-initialization.json), [Mac initialization](../tools/evaluation/results/native-initialization/macos-initialization.json), [mapped simulator kernels](../tools/evaluation/results/native-initialization/simulator-kernels.json) and [summary including RSS samples](../tools/evaluation/results/native-initialization/summary.json) are stored separately from the earlier boxed baseline. Reproduce with:

```sh
tools/native_benchmark/run.sh "$PWD/tools/evaluation/results/native-initialization" --mapped
python3 tools/native_benchmark/summarize_initialization.py
```

Use simulator config fields `mapped_seeds: true`, `iterations: 101`, `output` and `initialization_output` (absolute result paths) when running the isolated Release performance test. Remove the config afterward. `--memory-only` reruns RSS processes while retaining the timing reports.

## Next bounded slice

1. Port packed trie traversal/completions and search funding, preserving terminal identity, distinct traversal/terminal budgets, candidate order, channel costs and cancellation.
2. Add mutable-trie/update parity and immutable personalization boosts/epochs to the mapped seed path. Native retained static seed generation is implemented.
3. Add whole-request identity/evidence conversion and comparison; retain Swift production selection until the search gates pass.
4. Introduce immutable n-gram/personal/safety scoring views, migrate scoring, then policy/Glide.

The existing bridge owns a reader and retained DP audit sessions, not a full decoder engine. Model backend/state transport and request identity records are still planned. Restore matching trained models before neural parity; measure on a physical iPhone before claiming latency/RAM gains. See the root [migration plan](../CPP_IOS_MIGRATION_PLAN.md) for later stages and acceptance criteria.
