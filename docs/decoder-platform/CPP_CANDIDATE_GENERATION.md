# C++ candidate-generation pipeline

The English candidate backend uses portable `native/DecoderCore` modules for
generation, language scoring, ranking and correction. This migrates the existing
hybrid decoder; it does not enable a new neural model or change the search space.

## Ownership

C++ now implements:

- Mutable trie insert, lookup, frequency bump, weighted OSA search and completions.
  The independent Swift trie remains available in Debug/test builds only.
- Packed-trie word lookup and frequency-heap completions used by the generator.
  The original heap's equal-priority comparisons are preserved.
- Normal search selection, supplied retained-static candidates plus mutable search,
  context-injection alignment and admission, broad-recovery escalation, broad-pool
  truncation, channel-dominance guards and correction-display pool selection.
- Apostrophe-restoration proposal and closed-class synthetic contractions, plus
  the best exact two-word missing-space or space-neighbor split.
- Rank-derived and probability-derived traversal-funding mathematics. Reported
  candidate costs remain the original channel costs. Prefix funding cannot grant
  its bonus to an unrelated shorter terminal.

Swift supplies normalized input/tap buffers, n-gram successor words and their
Unicode character offsets, cached neural funding, and retained-static candidates.
Successor lengths preserve the old length gate for non-ASCII successor words.
Whole result batches return close/broad/injected/completion/display pools and
an optional split. No per-candidate lookup or safety callback runs inside C++.
Only the existing cancellation-ticket probe crosses back into Swift during walks.

`KBGenerationLexicon` retains the mapping owner, immutable boost/safety snapshot
and shared mutable-trie snapshots. Swift holds the vocabulary lock only while
capturing those views. Insert/bump uses native copy-on-write when an active
request still owns the old trie. A reset can replace the personal layer without
invalidating in-flight views. Boost snapshots invalidate on the existing learning
and reset mutations; no second independently mutable learning database exists.

The additional native modules own n-gram smoothing and successor merging
(`LanguageModel`), shortlist/final ranking and correction gates (`Ranking`),
Glide path preprocessing and beam search (`Glide`), bounded phrase expansion and
pruning (`Multiword`), and touch/glide adaptation statistics (`Adaptation`).
`NeuralSearch` owns SentencePiece tokenization, legal-token filtering, beam
generation, complete-word scoring and context planning. The Objective-C++ bridge
constructs Core ML tensors, runs model predictions and reads dense logits directly
from typed buffers when possible. The beam reuses legal-token masks across
hypotheses, avoiding a vocabulary-sized allocation at each step. Swift keeps
model loading, request identity,
cancellation, text normalization, and UI publication. There is still no bundled
trained GRU model, so native neural execution cannot be validated against a
running model yet.

## Reference path and boundaries

`KeyboardEngine(candidateBackend: .swiftReference)` keeps the independent Swift
search, ranker and correction implementation for Debug/test parity. The production
Unicode input path now supplies character offsets and first/last character
metadata to C++ rather than reverting to Swift search. Platform-specific Core ML
execution and mutable personalization persistence remain on iOS. Release excludes
large reference bodies, and native personal-count snapshots are cached until a
learning mutation invalidates them. This change does not alter budgets, score
weights, confidence thresholds, pack format, model-tier selection or request
identity.

The existing Swift ranker iterates a Dictionary and does not specify the order of
exactly equal scores; randomized hash seeds can even change a tied word at the
24-row evidence cutoff. The shared scheme therefore sets
`SWIFT_DETERMINISTIC_HASHING=1` for tests only. End-to-end comparisons require exact
candidate membership/order, source, costs, frequency/language/final scores, three
displayed suggestions and correction decisions. Production hashing/ranking is
unchanged. An earlier non-deterministic run exposed this pre-existing tie behavior;
it is not treated as evidence of an algorithm improvement.

## Verification

Run from the repository root:

```sh
native/tests/run.sh
cmake -S native -B /private/tmp/ioskeyboard-candidate-cmake -DCMAKE_BUILD_TYPE=Release
cmake --build /private/tmp/ioskeyboard-candidate-cmake -j 2
ctest --test-dir /private/tmp/ioskeyboard-candidate-cmake --output-on-failure
xcodebuild -project keyboard.xcodeproj -scheme keyboard -configuration Debug \
  -destination 'platform=iOS Simulator,id=<device-id>' \
  -derivedDataPath /private/tmp/ioskeyboard-candidate-migration \
  CODE_SIGNING_ALLOWED=NO test -only-testing:keyboardTests
```

`NativeCandidateGenerationTests` compares the mutable trie against its independent
Swift implementation; compares production packed completion/close pools; tests
snapshot lifetime, frequency learning/reset and cancellation; and replays 110
whole decodes across five contexts, including append/backspace, tap coordinates,
severe corruption, contractions, missing spaces and the Unicode fallback.

C++ goldens cover weighted transposition, frequency updates, severe channel cost,
missing/space-neighbor splits, blocked split halves, cancellation and funding.
The portable runner enables ASan/UBSan; CMake keeps assertions enabled in Release.

Device runtime latency/memory and trained-neural quality require separate checks.
A successful simulator test or cross-compiled device build does not establish them.

## First-slice checkpoint — 2026-10-20

Verification used an exported staged tree, excluding concurrent n-gram changes.
The simulator suite passed: 118 tests passed and one internal GRU-fixture test
was skipped. All 110 paired decodes matched exact candidate ordering, suggestions
and correction decisions with deterministic test hashing; numeric evidence used
the existing 1e-9 tolerance. The severe-typo benchmark committed `correction` in
155/155 replays across five contexts.

ASan/UBSan, both CMake/CTest executables, and the Glide CLI build passed.
The frozen tree cross-compiled for generic iOS arm64 Release with signing disabled;
the final extension passed the 24 MB full-vocabulary artifact gate at 20,008,775 bytes.
These are correctness/build checks, not device performance measurements.
See [machine-readable validation](candidate-generation-validation.json).

The first-slice checkpoint predates the remaining-component migration described
above. Re-run the listed checks on the final tree before treating them as final
validation; trained-model and physical-device measurements remain separate.

## Remaining-component checkpoint — 2026-10-20

The final-tree Debug device build and generic arm64 Release build succeeded. The
simulator ran 118 unit tests across seven suites with zero failures. Portable
ASan/UBSan goldens and all three CMake/CTest executables passed. The Release
`.appex` passed the full-vocabulary 24 MB gate at 20,144,343 bytes. The native
macOS benchmark measures retained-DP search kernels only, so its timings do not
establish end-to-end keyboard latency or neural-model performance. A trained
Core ML GRU and physical-device runtime measurements are still required for
those paths.

The isolated optimized macOS retained-DP benchmark measured 0.97 ms native
versus 10.38 ms Swift median for a one-character append, while native session
initialization took 22.86 ms versus 4.45 ms Swift. Five fresh-process peak-RSS
runs put the Swift seed path near 14.2 MB, boxed native near 19.8 MB and the
production-style mapped native path near 29.0 MB. The mapped path touches much
more of the 15 MB vocabulary file while selecting seeds, so this RSS comparison
does not establish a memory win; it identifies startup/page residency as the
next optimization target. These numbers are for the retained-DP harness, not
whole-request decode or iPhone latency.
