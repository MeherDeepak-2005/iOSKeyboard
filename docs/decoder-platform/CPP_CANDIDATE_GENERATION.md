# C++ English tap candidate generation

The default ASCII English tap path now calls the portable `generateCandidates`
backend in `native/DecoderCore/src/CandidateGeneration.cpp`. This is a parity
migration of the existing hybrid decoder, not a Neural Search Space redesign.

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
Swift Character counts, cached neural funding, and retained-static candidates.
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

## Reference and remaining work

`KeyboardEngine(candidateBackend: .swiftReference)` selects the previous pool
construction for comparisons. Production non-ASCII typed input also keeps this
Unicode-aware path. Swift still owns n-gram context extraction/successor merging,
final shortlisting/ranking/correction policy, internal neural multiword expansion,
Glide, neural tokenization/generation/scoring coordination, and iOS lifecycle/UI.
Those algorithms are not represented as migrated by this change. The existing
native packed/retained search and language-score arithmetic remain in place.

The engine retains Swift candidate construction for the later removal phase.
Normal Release already excludes the independent mutable-trie reference, and
builds no redundant Swift funding-prefix tree. This change does not enable a
neural model or change budgets, score weights, confidence thresholds, pack format,
model-tier selection or published request identity.

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

## Verified checkpoint — 2026-10-20

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
