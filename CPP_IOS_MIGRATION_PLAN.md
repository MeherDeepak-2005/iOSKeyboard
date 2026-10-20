> Current update: English candidate generation, ranking/correction, Unicode alignment, n-gram models, Glide, multiword search and portable neural-search mathematics now run in C++. See [scope, reference paths and verification](docs/decoder-platform/CPP_CANDIDATE_GENERATION.md). Swift still owns iOS lifecycle, model loading, mutable personalization persistence, and UI publication.

> Implementation boundary: Objective-C++ executes Core ML models and transports tensors; the portable core owns decoding policy. The Android bridge and trained-model/device-runtime validation remain separate work. See [current Android/iOS architecture](ANDROID_IOS_ARCHITECTURE.md) for the earlier cross-platform baseline.

# Planned C++ / iOS decoder migration

Status: **stage 2 in progress, packed reader, spatial, retained-DP and mapped-seed preparation slices implemented**. Production decoding still executes the repaired Swift/Core ML implementation. The original marking phase added only comments and this map. The subsequent implementation adds a portable packed-data reader, spatial costs, retained incremental DP, shared immutable native seed preparation, Objective-C++ bridge and opt-in parity comparisons; it does not switch the production decoder. All later destination markings remain planned. See [native implementation progress](native/README.md) for the current slice and remaining work.

The agreed sequence is **parity first, then Neural Search Space (NSS)**. English tap decoding and Glide migrate first. Telugu composition, Telugu vocabulary and Tenglish transliteration remain in Swift. iOS deployment stays at 18.0; Android integration is outside this plan.

## Reading the source markings

- `CPP_CORE`: planned portable C++20 algorithm/data ownership, independent of Apple frameworks.
- `SWIFT_IOS`: planned continued Swift/iOS ownership, including scheduling and public façades.
- `OBJCXX_BRIDGE`: planned Objective-C++ ownership of native conversion, Core ML execution, tensor/state access and error translation.
- `SPLIT`: the following `MIGRATION-SPLIT` comment explicitly assigns the parts to the labels above.

Each affected file has a `MIGRATION-FILE: planned ...` header. Migration-bound declarations have `MIGRATION: planned ... | stage=... | target=...` comments. Nested helpers inherit their enclosing ownership unless explicitly marked. Whole platform files inherit their Swift header. The stage and target name a future responsibility, not an existing C++ implementation. A mathematical body may move while its asynchronous wrapper remains Swift; neither its callback queue nor its identity checks may disappear.

## Ownership inventory

Paths are relative to the repository root. The detailed declaration index at the end maps the markings to real source declarations.

| Existing source | Planned responsibilities |
| --- | --- |
| [LangData.swift](keyboard/Engine/LangData.swift) | **CPP_CORE:** binary validation/reads, words/frequencies, n-grams, packed trie traversal, completions, anchor indexes and all incremental-session DP. **SWIFT_IOS:** discover/open/retain mapped resources. Initialization is split. |
| [Trie.swift](keyboard/Engine/Trie.swift) | **CPP_CORE:** `PriorNode`, `TrieSearchPrior`, mutable nodes/storage, insertion/lookup/search/recurse/completions and first-letter penalties. Preserve separate traversal funding and terminal funding/identity. |
| [Lexicon.swift](keyboard/Engine/Lexicon.swift) | **CPP_CORE:** lookup, corrections, broad recovery, incremental sessions, completions, frequency and mutable-trie/index updates. **SWIFT_IOS:** bundle loading, adoption/learning decisions, reset coordination and vocabulary revision publication. Insert and safety wrappers are split. |
| [SpatialModel.swift](keyboard/Engine/SpatialModel.swift) | **CPP_CORE:** `KB.subCost`, key geometry, row selection, tap adjustment and bucket statistics. **SWIFT_IOS:** `KeyTap` boundary record, defaults, serialization, saving/reset and lifecycle. Profile wrappers are split. |
| [NgramScorer.swift](keyboard/Engine/NgramScorer.swift) | **CPP_CORE:** score/interpolate/personal boosts, sequence/pair probabilities, successor merge and next words. Attach immutable vocabulary and personal views; eliminate per-word Swift lookup callbacks. |
| [MultiwordSearch.swift](keyboard/Engine/MultiwordSearch.swift) | **CPP_CORE:** hypotheses, segment cache, expansion, boundary costs, deduplication and per-position pruning. Preserve repaired current limits during parity. |
| [GlidePath.swift](keyboard/Engine/GlidePath.swift) | **CPP_CORE:** resampling, velocity/tangent features, pivots, nearest keys, retained candidates, decode, shape costs and beam heaps. **SWIFT_IOS:** extract UIKit geometry and convert points/layout once into numeric buffers. |
| [Keyboardengine.swift](keyboard/Engine/Keyboardengine.swift) | **CPP_CORE:** English candidate generation, costs, frequency/n-gram ranking, correction gates, contractions/splits, character priors, retained/multiword search and Glide mathematics. **SWIFT_IOS:** queues, request revisions, language routing, cancellation entrypoints, settings, persistence, diagnostics and main-thread publication. Decode/rank/neural expansion/Glide session methods are explicitly split. `GlideProfile` statistics move; persistence, locks and reset epochs stay Swift. |
| [CoreMLNeuralLanguagePrior.swift](keyboard/Engine/CoreMLNeuralLanguagePrior.swift) | **CPP_CORE:** tokenizer algorithms, constrained top-k, beam expansion, exact complete-word probability, boundary log-sum-exp and search-cache policy. **OBJCXX_BRIDGE:** model validation/prediction, tensor buffers, recurrent-state transport and native errors. **SWIFT_IOS:** protocol façades, artifact selection, readiness/lifecycle, settings and diagnostics. Neural network operations continue to use Core ML. |
| [DecodeContract.swift](keyboard/Engine/DecodeContract.swift) | **SWIFT_IOS:** public requests/snapshots, validity, casing and protocol façades. Portable mirror records are described below; no C++ containers reach controller code. |
| [UserModel.swift](keyboard/Engine/UserModel.swift) | **SWIFT_IOS:** learning, pruning, persistence/migration and reset epochs. Publish planned immutable count/adoption/confirmation snapshots to C++; never create a second independently mutable personal database. |
| [KBSafetyLexicon.swift](keyboard/Shared/KBSafetyLexicon.swift) | **SWIFT_IOS:** resource loading and normalization. **CPP_CORE:** immutable normalized lookup view used by filtering and penalties. Preserve every block/demotion rule. |

These files and all their platform processes remain planned **SWIFT_IOS**:

- [KeyboardViewController.swift](demo_keyboard/KeyboardViewController.swift): touch collection, layout extraction, accessibility, document insertion and UI/request ownership.
- `keyboard/Views/`: `Keyboard.swift`, `KeyboardLayout.swift`, `KeyButton.swift`, `SuggestionBar.swift`, `KeyboardTheme.swift`, `Emoji.swift`, `ClipboardPanel.swift`, `MediaPanel.swift`.
- `keyboard/Engine/`: `NativeDecoderParity.swift` (comparison transport), `TeluguComposer.swift`, `TeluguLexicon.swift`, `TenglishTransliterator.swift`.
- `keyboard/Shared/`: `KBSettings.swift`, `KBPersonalData.swift`, `KBDiagnostics.swift`, `KBStats.swift`, `LanguagePackHealth.swift`, `KBClipboard.swift`, `KBMediaCache.swift`, `KBKlipy.swift`, `UIColor+Hex.swift`. Settings/App Group storage, personal reset, diagnostics, clipboard/media and external API integrations stay Swift.

## Proposed modules and dependency direction

The table describes the complete future architecture. The packed-reader/spatial/retained-DP `DecoderCore` and audit `KBDecoderBridge.h/.mm` slices now exist; the full engine and Core ML backend remain planned.

| Future module / suggested location | Responsibility and dependency |
| --- | --- |
| `DecoderCore`, `native/DecoderCore/include/` and `src/` | C++20 packed vocabulary, mutable lexicon, spatial/n-gram models, ranking/correction policy, incremental/multiword/Glide search, tokenizer and neural-search mathematics. Depends only on portable records, standard C++ facilities and an abstract inference interface. No Foundation/UIKit/Core ML or Swift callbacks in search loops. |
| `native/iOS/KBDecoderBridge.h/.mm` | Objective-C-compatible public header and Objective-C++ implementation. Owns native engine/session handles; converts whole requests/results. Depends on DecoderCore and iOS resource lifetime owners. C++ types remain private to `.mm`. |
| `native/iOS/KBCoreMLBackend.h/.mm` | Objective-C++ adapter implementing portable inference using Core ML. Validates selected model schemas, accesses tensors, transports recurrent state and translates failures. Neural operators execute in Core ML, including its existing compute configuration. |
| Existing Swift engine façade | Owns iOS scheduling, resource/lifecycle events, language routing, settings, epochs, cancellation and publication. Calls bridge directly in process. Controller continues using Swift contracts. |

Dependency direction: controller → Swift façade → Objective-C++ decoder bridge → DecoderCore. DecoderCore calls a portable inference interface implemented by the Core ML backend; it does not import platform frameworks. Swift supplies immutable data views when resources or epochs change.

No HTTP/JSON/IPC communication layer is needed. Batch conversions at request boundaries. Do not call Swift once per trie node, candidate lookup, beam comparison or language-score operation.

## Proposed portable records and interfaces

These sketches describe the complete future boundary. The implemented reader/DP audit interfaces are recorded in native/README.md; whole-request identity, full ranking evidence and neural inference interfaces remain planned. Final signatures follow the parity implementation review.

| Record / operation | Planned contents / contract |
| --- | --- |
| `RequestIdentity` | Mirror `DecodeRequest.fieldRevision`, `documentRevision`, `wordSessionID`, `generation`, `layoutRevision` using explicit 64-bit identifiers. Preserve Glide session identity and async work-generation guards too. |
| `DecodeInput` | Identity; UTF-8 current word/context; taps as Double offsets plus explicit validity bits distinguishing nil arrays/nil taps; language mode; frozen requested model tier; vocabulary, personalization, model/session epochs; immutable layout/profile/keep-state views. Preserve order and existing normalization semantics. |
| `RankedEvidence` / `DecodeOutput` | Owned UTF-8 words, ordered suggestions, correction decision and all existing `DecodeCandidateEvidence` values: score, spatial cost, log frequency, log language probability, optional neural log probability, source and typed-word margin. Preserve snapshot identity, selected tier, keep/reject reasons and casing inputs used by Swift. |
| `MappedVocabularyView` | Read-only byte span and size with one retained backing owner. Validated format/offsets/version; no separate Swift/C++ corpus allocation. |
| `PersonalizationView` | Immutable unigram/bigram/trigram counts and totals, adopted vocabulary/frequencies, spelling confirmations and reset/revision epochs needed by current scoring/policy. Swift `UserModel` remains the mutable authority. |
| `SafetyView` | Immutable normalized blocked/demoted entries and exact current lookup/penalty semantics. Swift retains normalization and resource ownership. |
| `LayoutView` / `SpatialProfileView` | Numeric key centers, pitches/rows, Double profile values, layout revision; no CGPoint/CGFloat/UIColor in core. |
| `Engine.decode`, incremental append/reset, Glide begin/update/finish/cancel | Consume portable requests on façade-owned serialized execution lanes; own native retained search state; return owned results with unchanged identity. Internal cancellation token can be polled in long loops. Swift rejects stale completion before publication. |
| `InferenceBackend.prepareContext`, `predictBatch`, score/state operations | Portable token IDs, shape/stride metadata and owned/lifetime-controlled numeric buffers; native state handles; model/schema/tier identity and explicit errors. Batch model work while preserving tokenization, boundary events and score conventions. |

Swift public request/snapshot types remain intact. The bridge translates public values to portable records; conversion failures must produce existing failure behavior. No controller receives a `std::vector`, `std::string` or pointer into a temporary native buffer.

### Lifetime, threading and numerical rules

- Swift discovers/opens the mapped vocabulary and retains one backing allocation. The bridge keeps a lifetime token until every native reader/session using that backing is gone. Validate bounds before reads. A vocabulary update must not invalidate readers still referencing the old snapshot.
- Request text/touch/layout buffers must remain valid until consumption ends, including asynchronous work. Either transfer ownership or retain their owners. Published results own their strings/evidence/buffers.
- Snapshot personalization/safety at semantic update boundaries, tag with epochs and reuse across scoring. Reset coordination stays Swift; retire old snapshots and reject stale results consistently. Mutable lexicon updates are ordered with revision publication.
- Preserve serial execution/locks where current semantics require them. Do not allow concurrent mutation of native engine/model state without explicit ownership. Keep Swift queues, request coalescing, cancellation entrypoints, readiness coordination and main-thread callbacks.
- Freeze model tier for each word session. Preserve invalidation on context/document/layout/cursor changes, backspace, reset and memory pressure. Never silently switch tier mid-session.
- Keep Double precision for spatial and ranking math during parity. Preserve accumulation order, stable sorting/tie-breakers, caps and floating-point behavior; avoid fast-math rewrites. Model tensors retain their existing dtypes and model parity tolerances.
- Keep exact complete-word neural scores distinct from heuristic traversal bounds/funding. Preserve terminal identity and separate terminal funding. The current absolute-log-probability funding heuristic is not calibrated confidence.

Measured kernel/setup timings and Mac peak-RSS comparisons are recorded in [native/README.md](native/README.md). Native mapped seed creation and shared immutable preparation now remove the boxed setup regression: paired simulator seed selection plus creation takes 0.900 ms natively versus 2.608 ms in Swift. Mac peak RSS still regresses (19.14 MiB mapped native versus 10.55 MiB Swift). These are internal static-vocabulary measurements, not physical-iPhone or production decoder gains. Add immutable personalization boosts/epochs and finish search parity before enabling the backend.

## Migration stages and validation gates

| Stage | Work, prerequisites and exit gate |
| --- | --- |
| 1. Marking (completed) | Comments/documentation only. Verify declaration attachment and explicit splits; compare source to pre-marking contents after removing only migration comment lines. Preserve prior repairs/results. No backend switch or new runtime module. |
| 2. Portable search | Establish records/bridge lifetime ownership and immutable views, then move binary reads, packed/mutable trie and DP, spatial costs and n-gram scoring. Add an internal Swift/C++ comparison flag; retain Swift default until parity. Compare candidate evidence at search boundaries before policy changes. |
| 3. Policy and Glide | After search parity, move ranking/correction gates, contraction/split logic, multiword beam and Glide math. Keep Swift scheduling/resource façades. Compare retained-session and full-decode results, preview/final results and adoption/reset behavior. |
| 4. Neural boundary | Separate tokenizer/search/score math from Objective-C++ inference. Preserve current models, tokenizer, boundary scores, tensor conventions, caches and model tiers. Integrate batched state transport and stale/cancel handling. Deterministic fixtures verify plumbing; trained-model parity remains pending until matching artifacts are restored. |
| 5. NSS experiment | Only after migration parity passes, redesign neural search as a separate experiment with the repaired hybrid retained as baseline. Keep a reversible experiment flag, evaluate retrieval and ranking separately, and accept only measured quality/performance gains. |

Do not combine parity migration with threshold tuning, model/runtime replacement, weight changes, binary-format changes or an NSS production switch. Constrained neural proposals/terminal scoring in the current hybrid do not by themselves establish parity with Google's NSS decoder. C++ does not automatically improve contextual awareness; NSS quality depends on model/search coverage, funding and correction policy, independently of implementation language.

### Future parity acceptance

Require identical candidate coverage, ordering, suggestions and correction decisions. For deterministic Double costs/scores, compare within `1e-9`, while retaining existing Core ML parity tolerances from export/runtime checks. Investigate any tie/order difference even if numeric tolerance passes. No recall regression may be hidden by measuring only latency or final top-1 output.

Exercise:

- Empty context; severe typos; traversal/terminal funding and terminal identity; adopted words and vocabulary revisions; contractions; missing spaces and multiword pruning.
- Touch offsets and profile updates; append/backspace; cursor/document/layout changes; retained-session invalidation.
- Cancellation/coalescing; stale neural completions; readiness/model-tier freeze; reset epochs; memory pressure and recurrent-state lifetime.
- Glide begin/update/finish/cancel, preview/final ordering, layout changes, resampling/shape costs, supplementary vocabulary and learned profile math.

Re-run `coeevitjkn → correction` with and without the neural scorer in all five existing benchmark contexts:

1. Empty context `[]`.
2. `["auto"]`.
3. `["possibly", "receive"]`.
4. `["for", "definitely", "decided"]`.
5. `["could", "definitely", "receive"]`.

Use [SevereTypoBenchmark.swift](keyboardTests/SevereTypoBenchmark.swift) and preserve [the existing simulator result](tools/evaluation/results/coeevitjkn-simulator.json). That result is a simulator baseline, not physical-iPhone performance or evidence of C++ gains. Trained GRU/transformer Core ML artifacts and their matching tokenizer are unavailable on this laptop; neural-quality validation is **pending**. Fixtures establish plumbing only.

### Physical-device quality/performance gate

Use paired runs on the same actual iPhone, release configuration, dataset/context/touch traces, vocabulary and personalization snapshot, model tier and model artifacts. Report tap/Glide separately; compare Swift baseline, parity C++ and later NSS, with neural off/on where available. Include candidate recall@k, top-1/top-k suggestion accuracy, correction precision/recall, unintended corrections, missing-space accuracy and context-conditioned severe-typo results. Specify dataset denominator and uncertainty, not just a single typo success.

Measure cold/warm end-to-end p50/p95/p99 latency plus search/ranking/inference/boundary conversion stages; dropped/cancelled/stale work; startup/model warm-up; steady/peak physical memory footprint, mapped/private memory and allocations; vocabulary/model disk storage. Record device/OS, temperature/thermal state, run count and model compute settings. Core ML caching and shared mappings complicate RSS attribution: compare process-level peak/steady memory under matched conditions. C++ latency/RAM/storage gains remain unproven until these measurements exist. Establish product budgets from device baseline and keyboard-extension pressure behavior; do not invent gains or budgets in this marking phase.

## Marking-phase verification

The declaration index below is generated from the annotations and existing declarations. Verify each annotation attaches to its named declaration; every SPLIT has an explicit ownership description. For the original marking deliverable, strip only lines beginning with `// MIGRATION` (allowing indentation) from each marked source and compare with its pre-marking contents. Equality demonstrates that this turn leaves executable source and prior comments untouched. Separately verify hashes of the prior project configuration, repairs, tests, export tools and benchmark result. The overall working-tree diff also contains earlier uncommitted repairs, so it is not the scope of this marking-only comparison.

Swift syntax parsing and whitespace checks supplement that comparison. Runtime tests and physical-device benchmarking belong to subsequent implementation stages; comments do not supply runtime performance evidence.

### Historical marking-phase checks (2026-10-06)

- 33 marked Swift files exactly match their pre-marking contents after removing the added migration comment lines.
- 395 declaration annotations attach to existing declarations; all 81 SPLIT annotations specify multiple ownership destinations.
- All 10 separately protected project/repair/test/export/benchmark files retain their pre-marking hashes.
- `xcrun swiftc -frontend -parse` passed for all marked Swift files.
- `git diff --check` passed. No runtime build/test or physical-device performance claim is made by this comment-only validation.

## Declaration index

All destinations in this index are **planned**. File headers apply to platform-only files; their declarations are not individually repeated. Signatures below are the first source line of an existing declaration, including overloads; use the adjoining comments for the full ownership rationale.

### `demo_keyboard/KeyboardViewController.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Engine/CoreMLNeuralLanguagePrior.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated enum NeuralRuntimeState: String, Codable, Equatable, Sendable {` | SWIFT_IOS / platform / NeuralLifecycle | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private nonisolated final class KeyboardSentencePieceTokenizer: @unchecked Sendable {` | CPP_CORE / neural / Tokenizer | Preserve existing token IDs, byte fallback, English tag and word-boundary convention. |
| `init?(url: URL) {` | SPLIT / neural / Tokenizer | SWIFT_IOS resolves/maps the tokenizer resource; CPP_CORE validates and builds the exact existing token/boundary tables. |
| `func u32(_ offset: Int) -> Int {` | CPP_CORE / neural / Tokenizer | Preserve existing token IDs, byte fallback, English tag and word-boundary convention. |
| `func encode(_ text: String) -> [Int32] {` | CPP_CORE / neural / Tokenizer | Preserve existing token IDs, byte fallback, English tag and word-boundary convention. |
| `func word(fromPieceIDs ids: [Int32]) -> String {` | CPP_CORE / neural / Tokenizer | Preserve existing token IDs, byte fallback, English tag and word-boundary convention. |
| `final class CoreMLNeuralLanguagePrior: NeuralLanguagePrior, @unchecked Sendable {` | SPLIT / neural / NeuralFacade | CPP_CORE owns tokenization/search/score policy; OBJCXX_BRIDGE owns Core ML execution/tensor transport; SWIFT_IOS keeps protocol and lifecycle façades. |
| `private enum RuntimeError: LocalizedError {` | SPLIT / neural / NativeErrors | OBJCXX_BRIDGE translates native/model failures into bridge errors; SWIFT_IOS retains localized protocol-facing error presentation. |
| `private struct Session {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private final class Buffers {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `init?() {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private final class CandidateTokenCache {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `init(capacity: Int) { self.capacity = capacity }` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func value(for key: String) -> [Int32]? {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func insert(_ value: [Int32], for key: String) {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func removeAll() {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func bundled() -> CoreMLNeuralLanguagePrior {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `init(compiledURL: URL?, packageURL: URL? = nil, tokenizerURL: URL?) {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `deinit { pressureSource?.cancel() }` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `func prepareForSelection() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS selects artifacts, applies memory/cooldown gates and readiness policy; OBJCXX_BRIDGE loads/validates Core ML models. |
| `func prepareContext(_ words: [String], wordSessionID: UInt64) {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `func score(candidates: [String], wordSessionID: UInt64,` | SPLIT / neural / NeuralPipeline | SWIFT_IOS retains protocol/session/cancellation and completion semantics; CPP_CORE owns candidate/token/score orchestration; OBJCXX_BRIDGE executes model work. |
| `func discardSession(_ wordSessionID: UInt64) {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `func handleMemoryPressure() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS handles pressure/epochs/cooldown; CPP_CORE clears search caches; OBJCXX_BRIDGE releases model/tensor/state resources. |
| `private func loadModel() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS owns resource selection, epochs and state publication; OBJCXX_BRIDGE compiles/loads/validates Core ML models. |
| `private func validate(_ model: MLModel) throws {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func performScore(_ candidates: [String], session: Session,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private func trimmedContext(_ tokens: [Int32], maximumCandidateTokens: Int) -> [Int32] {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func ensureCurrent(_ session: Session, wordSessionID: UInt64) throws {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `private func fillTokens(_ array: MLMultiArray, rows: [[Int32]], context: [Int32],` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func fillScoringInputs(_ buffers: Buffers, rows: [[Int32]],` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func readScores(_ array: MLMultiArray, count: Int) -> [Double]? {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func installMemoryPressureHandler() {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `private func setState(_ state: NeuralRuntimeState, detail: String?, retainModel: Bool,` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `private func publishState() {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `final class GRULanguagePrior: NeuralLanguagePrior, NeuralSearchPrior, @unchecked Sendable {` | SPLIT / neural / NeuralFacade | CPP_CORE owns tokenization/search/score policy; OBJCXX_BRIDGE owns Core ML execution/tensor transport; SWIFT_IOS keeps protocol and lifecycle façades. |
| `private enum GRUError: Error { case notReady, badOutput, cancelled }` | SPLIT / neural / NativeErrors | OBJCXX_BRIDGE translates model-output failures; SWIFT_IOS retains readiness/cancellation and protocol-facing error presentation. |
| `private struct Session { let contextTokens: [Int32] }` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private struct WarmJob {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `static func bundled() -> GRULanguagePrior {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `init(compiledURL: URL?, packageURL: URL?, tokenizerURL: URL?,` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `func prepareForSelection() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS selects artifacts, applies memory/cooldown gates and readiness policy; OBJCXX_BRIDGE loads/validates Core ML models. |
| `private func loadModel(epoch: UInt64) {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS owns resource selection, epochs and state publication; OBJCXX_BRIDGE compiles/loads/validates Core ML models. |
| `private func validateStepModel(_ model: MLModel) throws {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func loadScoreModel(configuration: MLModelConfiguration) -> MLModel? {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `func prepareContext(_ words: [String], wordSessionID: UInt64) {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `func discardSession(_ wordSessionID: UInt64) {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `func handleMemoryPressure() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS handles pressure/epochs/cooldown; CPP_CORE clears search caches; OBJCXX_BRIDGE releases model/tensor/state resources. |
| `func cancelPendingSearch() {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `func searchPriorWords(_ query: SearchPriorQuery) -> [SearchPriorWord]? {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns exact query keys, cache lookup and LRU; SWIFT_IOS supplies vocabulary/model epochs and records hit/miss diagnostics. |
| `func warmSearchPrior(_ query: SearchPriorQuery, isKnownWord: @escaping (String) -> Bool) {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS coalesces/schedules and publishes current readiness; CPP_CORE owns query/seed and search-cache policy; OBJCXX_BRIDGE executes model batches. |
| `private func isCurrent(_ job: WarmJob) -> Bool {` | SWIFT_IOS / platform / NeuralLifecycle | Keep bundle selection, runtime-state diagnostics, platform notifications and lifecycle coordination in Swift. |
| `private func drainWarmJobs() {` | SPLIT / neural / NeuralPipeline | SWIFT_IOS owns job scheduling, epoch/cancellation checks and notifications; CPP_CORE generates/ranks and manages cache policy; OBJCXX_BRIDGE executes predictions. |
| `private static func matchesPrefix(_ word: String, firstLetters: Set<Character>?) -> Bool {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func rankPool(_ pool: [String], context: [String], model: MLModel,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private struct BeamHypothesis {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private func generateNextWords(context: [String], model: MLModel,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns legal-token filtering, beam hypotheses and complete-word scoring; OBJCXX_BRIDGE predicts recurrent steps; SWIFT_IOS supplies cancellation/epoch validity. |
| `private static func startLetterAllowed(_ index: Int, firstLetters: Set<Character>?,` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func logProbabilities(_ array: MLMultiArray) -> [Float]? {` | SPLIT / neural / NeuralPipeline | OBJCXX_BRIDGE extracts checked stride-aware logits; CPP_CORE calculates finite log-softmax values. |
| `private static func boundaryLogProbability(_ logProbabilities: [Float],` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func topIndices(_ values: [Float], count: Int, allowed: (Int) -> Bool = { _ in true }) -> [Int32] {` | CPP_CORE / neural / NeuralSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func score(candidates: [String], wordSessionID: UInt64,` | SPLIT / neural / NeuralPipeline | SWIFT_IOS retains protocol/session/cancellation and completion semantics; CPP_CORE owns candidate/token/score orchestration; OBJCXX_BRIDGE executes model work. |
| `private func streamScore(_ candidates: [String], session: Session, model: MLModel,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private func streamScoreSingleStep(_ candidates: [String], session: Session, model: MLModel,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private func batchScore(_ candidates: [String], session: Session, stepModel: MLModel,` | SPLIT / neural / NeuralPipeline | CPP_CORE owns token/beam/context/complete-word score policy; OBJCXX_BRIDGE owns model execution and tensor/state transport; SWIFT_IOS owns session/epoch/cancellation coordination. |
| `private static func isContiguous(_ array: MLMultiArray) -> Bool {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private static func readVector(_ array: MLMultiArray, count: Int) -> [Double]? {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func runContext(_ tokens: [Int32], model: MLModel) throws -> MLMultiArray {` | SPLIT / neural / NeuralPipeline | CPP_CORE owns context-token/state-cache policy; OBJCXX_BRIDGE owns recurrent-state transport/prediction; SWIFT_IOS coordinates model/session epochs. |
| `private func step(_ token: Int32, state: MLMultiArray, model: MLModel) throws` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func zeroState() throws -> MLMultiArray {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private func duplicate(_ source: MLMultiArray) throws -> MLMultiArray {` | OBJCXX_BRIDGE / neural / KBCoreMLBackend | Own MLModel/MLMultiArray interaction and checked tensor transport; expose portable numeric results and translated errors. |
| `private static func logSoftmax(_ array: MLMultiArray, at index: Int) -> Double {` | SPLIT / neural / NeuralPipeline | OBJCXX_BRIDGE exposes checked logits; CPP_CORE evaluates the log-softmax kernel at the requested index. |

### `keyboard/Engine/DecodeContract.swift` — planned SWIFT_IOS

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `enum DecodeModelTier: String, Codable, Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct DecodeRequest: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `init(fieldRevision: UInt64, documentRevision: UInt64, wordSessionID: UInt64,` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `enum DecodeCandidateSource: String, Codable, Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct DecodeCandidateEvidence: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `init(word: String, score: Double, spatialCost: Double, logFrequency: Double,` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `protocol NeuralLanguagePrior: AnyObject {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func prepareContext(_ words: [String], wordSessionID: UInt64)` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func score(candidates: [String], wordSessionID: UInt64,` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func discardSession(_ wordSessionID: UInt64)` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func prepareForSelection()` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func handleMemoryPressure()` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct SearchPriorWord: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct SearchPrefix: Equatable, Hashable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct SearchPriorQuery: Equatable, Hashable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `init(context: [String], prefix: SearchPrefix?, pool: [String], vocabularyRevision: UInt64 = 0) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `protocol SearchPriorProvider: AnyObject {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func warmSearchPrior(_ query: SearchPriorQuery, isKnownWord: @escaping (String) -> Bool)` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func searchPriorWords(_ query: SearchPriorQuery) -> [SearchPriorWord]?` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `protocol NeuralSearchPrior: SearchPriorProvider, NeuralLanguagePrior {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func cancelPendingSearch()` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func cancelPendingSearch() {}` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func prepareForSelection() {}` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func handleMemoryPressure() {}` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct DecodeSnapshot: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func isValid(for current: DecodeRequest) -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct PresentedSuggestion: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `struct PresentedDecodeSnapshot: Equatable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func isValid(for request: DecodeRequest) -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `enum SuggestionCasePolicy {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `static func present(_ snapshot: DecodeSnapshot, sentenceStart: Bool)` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `static func display(_ candidate: String, typedWord: String? = nil,` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private static func intrinsicEnglishCase(_ value: String) -> String {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private static func isIForm(_ value: String) -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private static func initialCapital(_ value: String) -> String {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |

### `keyboard/Engine/GlidePath.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated struct GlideLayout {` | SPLIT / policy-glide / LayoutSnapshot | SWIFT_IOS extracts UIKit geometry; CPP_CORE receives owned numeric centers/pitches without CGPoint or CGFloat dependencies. |
| `nonisolated struct ProcessedGlide {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `nonisolated struct IncrementalGlideResampler {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `init(spacing: CGFloat = 0.5) { self.spacing = spacing }` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `mutating func append(_ points: ArraySlice<CGPoint>) -> [CGPoint] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `nonisolated struct OnlineGlideCandidate {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `init?(word: String, idealPointCount: Int = 24) {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `mutating func consume(_ samples: [CGPoint]) {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `nonisolated enum GlidePreprocess {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func run(_ raw: [CGPoint], layout: GlideLayout, spacing: CGFloat = 0.5,` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func velocityFeatures(grid: [CGPoint], times: [TimeInterval], resampled: [CGPoint],` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func nearestIndex(to p: CGPoint, in pts: [CGPoint]) -> Int {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func mergeSortedUnique(_ a: [Int], _ b: [Int]) -> [Int] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func toGrid(_ p: CGPoint, layout: GlideLayout) -> CGPoint {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func pivots(_ pts: [CGPoint], cosThreshold: CGFloat = 0.5) -> [Int] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func lettersNear(_ p: CGPoint, radius: CGFloat, maxN: Int) -> [Character] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func nearestLetter(toGrid p: CGPoint) -> Character? {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `nonisolated enum GlideDecoder {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func decode(_ g: ProcessedGlide, lang: LangData,` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `struct PathNode { let point: CGPoint; let parent: Int }` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `struct Hyp { let node: Int; let j: Int; let prune: Double; let key: Double; let pathIndex: Int }` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func shapeCost(of word: String, _ g: ProcessedGlide,` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `static func idealPath(for word: String, pointCount: Int) -> [CGPoint]? {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func shapeCost(_ obs: [CGPoint], _ obsTan: [CGPoint],` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func tangents(_ pts: [CGPoint]) -> [CGPoint] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func resampleN(_ pts: [CGPoint], _ n: Int) -> [CGPoint] {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func gridCenter(_ label: UInt8) -> CGPoint? { gridCenter(Character(Unicode.Scalar(label))) }` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func gridCenter(_ ch: Character) -> CGPoint? {` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |
| `private static func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }` | CPP_CORE / policy-glide / GlideSearch | Convert platform geometry once at the boundary; preserve resampling, DTW, dwell detection and beam ordering. |

### `keyboard/Engine/Keyboardengine.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated struct GlidePrediction {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `nonisolated struct GlideSessionID: Hashable, Sendable {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `nonisolated struct GlideUpdate {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `final class KeyboardEngine {` | SPLIT / policy-glide / DecoderFacade | CPP_CORE owns English/Glide candidate generation, retained search and scoring; SWIFT_IOS owns scheduling, settings, language routing and result publication. |
| `private struct GlidePreviewCache {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func maxCost(for length: Int) -> Double {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private struct RankedCandidate {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func isKept(_ word: String) -> Bool { sessionKept.contains(word) }` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func scheduleSave() {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `init(languageDataURL: URL? = nil, rescorer: NeuralLanguagePrior? = nil,` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func preferredModelTier(for languageMode: KBLanguageMode) -> DecodeModelTier {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func handleMemoryPressure() {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func discardModelSession(_ wordSessionID: UInt64) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func applyLearned() {` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS loads personal counts and adoption policy; CPP_CORE receives bounded immutable boosts and mutable-trie update events. |
| `func resetPersonalization(to epoch: UInt64 = KBPersonalData.currentEpoch) {` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS advances/reset storage epochs; CPP_CORE clears mutable vocabulary/search snapshots; OBJCXX_BRIDGE invalidates inference state. |
| `private struct CorrectionDecision {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func rawScore(_ candidate: RankedCandidate) -> Double {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func contractionPreservingTypedSuffix(base: String, typed lw: String) -> String? {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func contextualCharPriors(evidence: [DecodeCandidateEvidence], prefix lw: String,` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func correction(from scored: [RankedCandidate], correctionCosts: [String: Double],` | SPLIT / policy-glide / DecoderFacade | CPP_CORE applies the existing correction/channel/runner-up gates using a supplied keep-state view; SWIFT_IOS records the decision diagnostics. |
| `private static func nearForm(_ a: String, _ b: String) -> Bool {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func splitCandidate(of lw: String) -> (candidate: Candidate, a: String, b: String)? {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func multiwordCandidates(typed: String, taps: [KeyTap?]?, request: DecodeRequest,` | SPLIT / policy-glide / DecoderFacade | CPP_CORE expands, scores and prunes phrase hypotheses; OBJCXX_BRIDGE executes model work; SWIFT_IOS schedules callbacks and rejects stale generations. |
| `func dontCorrect(_ word: String) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func correctionStood(_ original: String) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func wordReplaced(original: String, with replacement: String) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private struct StreamingGlideSession {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func currentGlidePreviewGeneration() -> Int {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func isCurrentGlidePreview(_ generation: Int) -> Bool {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func cancelGlidePreviews() {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func beginGlideSession(context: [String]) -> GlideSessionID {` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS assigns session/revision identity and schedules work; CPP_CORE initializes its portable hypothesis/resampler state. |
| `func cancelGlideSession(_ id: GlideSessionID) {` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS invalidates ownership/generations; CPP_CORE releases retained session state. |
| `func updateGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS captures/converts input, validates identity and publishes previews; CPP_CORE consumes samples and updates/ranks hypotheses. |
| `func finishGlideSession(_ id: GlideSessionID, path: [CGPoint], times: [TimeInterval],` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS validates ownership and delivers one final result; CPP_CORE finalizes and ranks the portable Glide session. |
| `private func consumeStreamingPath(_ path: [CGPoint], layout: GlideLayout,` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS converts UIKit layout/points to numeric buffers; CPP_CORE resamples and consumes the retained trajectory. |
| `private func augmentStreamingCandidates(languageData: LangData,` | SPLIT / policy-glide / DecoderFacade | CPP_CORE expands/prunes anchors and dynamic-word candidates; SWIFT_IOS supplies snapshot inputs and handles diagnostics/cancellation. |
| `private func rankStreamingCandidates(_ session: StreamingGlideSession) -> GlidePrediction? {` | SPLIT / policy-glide / DecoderFacade | CPP_CORE scores/ranks retained Glide evidence; SWIFT_IOS retains diagnostics and result packaging. |
| `func glidePreview(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout,` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS schedules, rejects stale work and publishes UI previews; CPP_CORE generates and ranks the numerical search results. |
| `private func storeGlidePreview(_ prediction: GlidePrediction, key: UInt64) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func recentGlidePreview(key: UInt64) -> GlidePrediction? {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func glideCacheKey(path: [CGPoint], times: [TimeInterval], layout: GlideLayout,` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func scoreGlideCandidates(_ candidates: [(word: String, cost: Double)],` | SPLIT / policy-glide / DecoderFacade | CPP_CORE combines shape, frequency and language scores; OBJCXX_BRIDGE services neural batches; SWIFT_IOS coordinates asynchronous completion. |
| `private struct GlideDecodeResult {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func decodeGlide(_ glide: ProcessedGlide, lang: LangData, context: [String],` | SPLIT / policy-glide / DecoderFacade | CPP_CORE performs beam/shape/admission search; SWIFT_IOS supplies cancellation identity and records diagnostics. |
| `func glide(path: [CGPoint], times: [TimeInterval] = [], layout: GlideLayout, context: [String],` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS owns language routing, queue/identity and callbacks; CPP_CORE owns English Glide search/scoring; OBJCXX_BRIDGE services neural work. |
| `private func logCachedGlide(_ prediction: GlidePrediction, path: [CGPoint], times: [TimeInterval],` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func dwelledDoubles(_ word: String, _ dwell: Set<Character>) -> Int {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private struct GlideOutcome {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func noteGlideCommit(winner: String, shapeCostByWord: [String: Double]) -> String {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func takeGlideOutcome() -> GlideOutcome? {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func glideUnverified() { _ = takeGlideOutcome() }` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func glideCorrected(to word: String) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func glideRejected() { _ = takeGlideOutcome() }` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func isLatest(_ gen: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return gen == suggestGen }` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func cancelSuggestions() {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func spatialCost(typed t: String, target g: String, taps: [KeyTap?]? = nil) -> Double {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func contextInjectedCandidates(typed lw: String, context: [String],` | SPLIT / policy-glide / DecoderFacade | CPP_CORE selects successors and computes channel admission; SWIFT_IOS supplies normalized safe inputs and the immutable safety view. |
| `private func tenglishToTeluguSnapshot(for request: DecodeRequest) -> DecodeSnapshot {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func romanTeluguSnapshot(for request: DecodeRequest) -> DecodeSnapshot {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func immediateBoundarySnapshot(_ request: DecodeRequest) -> DecodeSnapshot? {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func retainedDecodeSession(for request: DecodeRequest, word: String,` | SPLIT / policy-glide / DecoderFacade | CPP_CORE owns seeds, DP columns and append/reset logic; SWIFT_IOS validates word-session/layout identity and coordinates lifetime. |
| `func decode(_ request: DecodeRequest, completion: @escaping (DecodeSnapshot) -> Void) {` | SPLIT / policy-glide / DecoderFacade | CPP_CORE computes English candidates, ranking and correction; SWIFT_IOS routes languages, retains revision/generation identity, schedules work and publishes on main. |
| `func suggestions(currentWord: String, context: [String], taps: [KeyTap?]? = nil,` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func importSupplementaryLexicon(_ words: [String]) {` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS schedules/imports and publishes vocabulary revisions; CPP_CORE inserts the supplied normalized words. |
| `func learn(context: [String], word: String) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `func learnTouchProfile(word: String, taps: [KeyTap?]) {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private func allowsPersonalAdoption(of word: String, count: Int) -> Bool {` | SWIFT_IOS / platform / KeyboardLifecycle | Keep platform scheduling, identity, persistence, learning events and UI publication outside the portable core. |
| `private enum FrequencyMode { case raw, compressed }` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func frequencyTerm(_ logFreq: Double, mode: FrequencyMode) -> Double {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func rankNgram(_ cands: [Candidate], including extra: Candidate? = nil,` | SPLIT / policy-glide / DecoderFacade | CPP_CORE deduplicates, filters, calculates probabilities/scores and ranks; SWIFT_IOS retains optional diagnostic logging outside the math kernel. |
| `private func rank(_ cands: [Candidate], including extra: Candidate? = nil,` | SPLIT / policy-glide / DecoderFacade | CPP_CORE deduplicates, blends scores, sorts and caps candidates; OBJCXX_BRIDGE executes model batches; SWIFT_IOS validates generations and emits diagnostics/completion. |
| `private func contextSearchPrior(_ context: [String], typedPrefix lw: String = "",` | SPLIT / policy-glide / DecoderFacade | CPP_CORE forms constrained query keys, seed pools and funding; SWIFT_IOS gates settings/epochs and readiness publication; OBJCXX_BRIDGE services neural work. |
| `private func plausibleFirstLetters(typedPrefix lw: String, taps: [KeyTap?]?) -> Set<Character> {` | CPP_CORE / policy-glide / DecoderPolicy | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func userAdoptedNextWords(context: [String], excluding seen: Set<String>,` | SPLIT / policy-glide / DecoderFacade | SWIFT_IOS supplies an epoch-tagged immutable personal-count snapshot; CPP_CORE filters/ranks adopted successors without per-word Swift callbacks. |
| `private func neuralNextWords(context: [String], seed pool: [String], limit: Int = 24) -> [String] {` | SPLIT / policy-glide / DecoderFacade | CPP_CORE selects cached generated words and seeds; SWIFT_IOS owns settings and readiness/cancellation coordination; OBJCXX_BRIDGE services prediction batches. |
| `private func nextWords(context: [String]) -> [String] {` | SPLIT / policy-glide / DecoderFacade | CPP_CORE merges and ranks n-gram, personal and neural continuations; SWIFT_IOS gates platform settings and emits diagnostics. |
| `final class GlideProfile {` | SPLIT / policy-glide / GlideAdaptation | CPP_CORE owns EWMA/statistical updates; SWIFT_IOS owns epoch checks, locks, persistence and publication of profile values. |
| `private nonisolated struct State: Codable {` | SPLIT / policy-glide / GlideAdaptation | CPP_CORE receives a numeric statistics mirror; SWIFT_IOS retains Codable storage and the personal-data epoch. |
| `func load() {` | SWIFT_IOS / platform / GlideProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func persist(_ s: State) {` | SWIFT_IOS / platform / GlideProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func snapshot() -> State { lock.lock(); defer { lock.unlock() }; return state }` | SWIFT_IOS / platform / GlideProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func observeCorrect(cost: Double) {` | SPLIT / policy-glide / GlideAdaptation | CPP_CORE owns EWMA/statistical updates; SWIFT_IOS owns epoch checks, locks, persistence and publication of profile values. |
| `func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) {` | SWIFT_IOS / platform / GlideProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func blend(_ n: Int) -> Double { min(1.0, Double(n) / Self.warmup) }` | CPP_CORE / policy-glide / GlideAdaptation | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `var sigma: Double {` | SPLIT / policy-glide / GlideAdaptation | CPP_CORE bounded calculation; SWIFT_IOS locked epoch-tagged snapshot. |
| `var gate: Double {` | SPLIT / policy-glide / GlideAdaptation | CPP_CORE bounded calculation; SWIFT_IOS locked epoch-tagged snapshot. |

### `keyboard/Engine/LangData.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated struct IncrementalLexiconSeed {` | CPP_CORE / search / IncrementalSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated final class IncrementalDecodeSession {` | SPLIT / search / IncrementalSearch | CPP_CORE owns retained seed/DP state and channel candidate mathematics; SWIFT_IOS owns comparison-mode lifetime, native buffer conversion and audit diagnostics. |
| `init(seeds: [IncrementalLexiconSeed], compareNativeSearch: Bool = false) {` | SPLIT / search / IncrementalSearch | CPP_CORE initializes owned native seeds and DP columns; SWIFT_IOS retains the baseline session and controls opt-in shadow comparison. |
| `func advance(to word: String, taps: [KeyTap?]? = nil) -> Bool {` | SPLIT / search / IncrementalSearch | CPP_CORE advances/resets normalized English DP columns; SWIFT_IOS normalizes boundary input, packs optional taps and audits retained identity/result parity. |
| `func candidates(maxCost: Double) -> [Candidate] {` | SPLIT / search / IncrementalSearch | CPP_CORE applies channel/first-letter costs and emits seed-ordered candidates; SWIFT_IOS converts owned evidence and audits coverage, order and Double parity. |
| `private func resetRows() {` | CPP_CORE / search / IncrementalSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func append(_ byte: UInt8, tap: KeyTap?) {` | CPP_CORE / search / IncrementalSearch | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated final class LangData {` | SPLIT / search / PackedLexicon | CPP_CORE owns packed validation, reads and search; SWIFT_IOS discovers/maps/retains resources and runs opt-in comparison audits. |
| `init?(url: URL, compareNativeReads: Bool = false) {` | SPLIT / search / MappedVocabulary | SWIFT_IOS opens and retains one mapped backing; CPP_CORE validates bytes, offsets, versions, and initializes the reader. |
| `func starterIDs(limit: Int) -> [Int] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func u32(_ off: Int) -> Int {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func u16(_ off: Int) -> Int {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func freq(_ id: Int) -> Int { u32(freqBase + 4 * id) }` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func word(_ id: Int) -> String {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func forEachWord(_ body: (String, Int, Int32) -> Void) {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func anchorKey(_ first: UInt8, _ last: UInt8) -> UInt16 { UInt16(first) << 8 \| UInt16(last) }` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func buildAnchorIndex() -> [UInt16: [Int32]] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func warmGlideAnchorIndex() {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func glideAnchorWords(first: [Character], last: [Character], perBucket: Int) -> [String] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func mix64(_ x: UInt64) -> UInt64 {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func bigrams(after ctx: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trigrams(after w1: Int32, _ w2: Int32, limit: Int? = nil) -> (total: Int, entries: [(word: Int32, count: Int)])? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func bigramCounts(after ctx: Int32, words: [Int32])` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trigramCounts(after w1: Int32, _ w2: Int32, words: [Int32])` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func bigramRange(after ctx: Int32) -> (total: Int, start: Int, count: Int)? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func trigramRange(after w1: Int32, _ w2: Int32)` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func selectedCounts(base: Int, range: (total: Int, start: Int, count: Int),` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func entries(_ base: Int, _ start: Int, _ end: Int) -> [(word: Int32, count: Int)] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func nodeByte(_ node: Int, _ off: Int) -> Int {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func nodeU32(_ node: Int, _ off: Int) -> UInt32 {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func nodeWordID(_ node: Int) -> UInt32 {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func nodeMaxFreq(_ node: Int) -> UInt32 {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func trieNode(for word: [UInt8]) -> Int? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieContains(_ lw: String) -> Bool {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieApostropheRestoration(of lw: String) -> (word: String, freq: Int)? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieHasPrefix(_ lw: String) -> Bool { trieNode(for: Array(lw.utf8)) != nil }` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieWordID(_ lw: String) -> Int32? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func incrementalSeeds(typedFirst: UInt8, firstTap: KeyTap?,` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieSearch(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieChildren(after prefix: String) -> [(label: UInt8, maxFreq: UInt32)] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieCompletions(prefix: String, limit: Int) -> [Candidate] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `struct Entry { let priority: UInt32; let node: Int; let wordID: Int32 }` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieChildren(ofNode node: Int) -> [(label: UInt8, node: Int)] {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func forEachChild(ofNode node: Int, _ body: (_ label: UInt8, _ node: Int) -> Void) {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieWord(atNode node: Int) -> String? {` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func trieMaxFreq(ofNode node: Int) -> UInt32 { nodeMaxFreq(node) }` | CPP_CORE / search / PackedLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |

### `keyboard/Engine/Lexicon.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `final class Lexicon {` | SPLIT / search / LexiconFacade | CPP_CORE owns lookup/search and mutable-trie storage; SWIFT_IOS owns resources, adoption events, reset and revision publication. |
| `func isProfane(_ w: String) -> Bool {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves normalization; CPP_CORE queries the immutable normalized safety view without search-loop callbacks. |
| `func safetyPenalty(_ word: String) -> Double {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves normalization; CPP_CORE queries the immutable normalized safety view without search-loop callbacks. |
| `func isSafeToLearn(_ word: String) -> Bool {` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |
| `func contains(_ lw: String) -> Bool {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func isStaticWord(_ lw: String) -> Bool {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func isPrefix(_ lw: String) -> Bool {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func isContractionForm(_ lw: String) -> Bool {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func apostropheRestoration(of lw: String) -> String? {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func syntheticContraction(of lw: String) -> String? {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func insert(_ lw: String, freq: Int) {` | SPLIT / search / LexiconView | CPP_CORE updates mutable vocabulary and supplementary Glide indexes; SWIFT_IOS coordinates locking and publishes vocabulary revisions. |
| `func glideDynamicWords(limit: Int) -> [String] {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func isGlideSpelling(_ word: String) -> Bool {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func wordID(_ lw: String) -> Int32? {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func languageDataSnapshot() -> LangData? {` | SWIFT_IOS / platform / MappedResourceOwner | Expose a lifetime-safe view of the shared backing; do not duplicate the mapped corpus. |
| `func corrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func makeIncrementalDecodeSession(typedFirst: UInt8,` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func mutableCorrections(for lw: String, maxCost: Double,` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func broadCorrections(for lw: String, maxCost: Double, taps: [KeyTap?]? = nil,` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func nextCharPriors(prefix lw: String) -> [Character: Double] {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func logFreq(of lw: String) -> Double? {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func completions(prefix lw: String, limit: Int) -> [Candidate] {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func applying(_ boosts: [String: Int], to candidate: Candidate) -> Candidate {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func boosted(_ c: Candidate) -> Candidate {` | CPP_CORE / search / LexiconView | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func noteUse(of lw: String, timesUsed: Int, adoptAfter: Int,` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |
| `func resetPersonalization() {` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |
| `private func sentenceCase(_ w: String) -> String {` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |
| `func loadFromBundle() {` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |
| `func load(from url: URL?) {` | SWIFT_IOS / platform / VocabularyLifecycle | Publish vocabulary/personalization changes at semantic boundaries; preserve storage, adoption and reset policy. |

### `keyboard/Engine/MultiwordSearch.swift` — planned CPP_CORE

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated final class MultiwordSearch {` | CPP_CORE / policy-glide / MultiwordBeam | Preserve current segmentation limits and true channel costs. |
| `struct Hypothesis {` | CPP_CORE / policy-glide / MultiwordBeam | Preserve current segmentation limits and true channel costs. |
| `init(typed: String, taps: [KeyTap?]?, candidates: @escaping (String, [KeyTap?]?) -> [Candidate]) {` | CPP_CORE / policy-glide / MultiwordBeam | Preserve current segmentation limits and true channel costs. |
| `func expand(_ frontier: [Hypothesis], shouldCancel: () -> Bool) -> [Hypothesis] {` | CPP_CORE / policy-glide / MultiwordBeam | Preserve current segmentation limits and true channel costs. |

### `keyboard/Engine/NgramScorer.swift` — planned CPP_CORE

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `final class NgramScorer {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `init(user: UserModel) { self.user = user }` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func attach(data: LangData?, resolveID: @escaping (String) -> Int32?, lexicon: Lexicon) {` | SPLIT / search / NgramModelView | SWIFT_IOS supplies epoch-tagged immutable vocabulary/personalization views; CPP_CORE attaches them without per-word Swift callbacks. |
| `func logProbs(_ candidates: [String], context: [String]) -> [Double] {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func pairLogProb(_ a: String, _ b: String, context: [String]) -> Double {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func sequenceLogProb(_ words: [String], context: [String]) -> Double {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func score(_ words: [String], context: [String]) -> [Double] {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func interpolate(total rawTotal: Int, types rawTypes: Int,` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func personalBoost(_ count: Int, weight: Double) -> Double {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func nextWords(context: [String], limit: Int) -> [String] {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func merged(_ base: [(word: Int32, count: Int)]?, _ userCounts: [String: Int]) -> [String] {` | CPP_CORE / search / NgramScorer | Preserve existing coverage, ordering, costs, limits and score conventions. |

### `keyboard/Engine/SpatialModel.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated struct KeyTap: Equatable {` | SWIFT_IOS / platform / DecodeBoundary | Keep the Swift boundary value; mirror dx/dy as Double in the portable request. |
| `final class TouchSpatialProfile {` | SPLIT / search / TouchProfile | CPP_CORE owns tap-adjustment/statistics math; SWIFT_IOS owns loading, serialization, defaults and reset coordination. |
| `private struct Bucket: Codable, Equatable {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `mutating func observe(_ tap: KeyTap) {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private struct Stored: Codable, Equatable {` | SPLIT / search / TouchProfile | CPP_CORE owns tap-adjustment/statistics math; SWIFT_IOS owns loading, serialization, defaults and reset coordination. |
| `init(defaults: UserDefaults = KBSettings.sharedDefaults) {` | SWIFT_IOS / platform / TouchProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func adjusted(_ taps: [KeyTap?]?, typed: String) -> [KeyTap?]? {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func observe(word: String, taps: [KeyTap?],` | SPLIT / search / TouchProfile | CPP_CORE updates bucket statistics; SWIFT_IOS owns unsaved-sample bookkeeping and save scheduling. |
| `func save(defaults: UserDefaults = KBSettings.sharedDefaults) {` | SWIFT_IOS / platform / TouchProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func reset(defaults: UserDefaults = KBSettings.sharedDefaults) {` | SWIFT_IOS / platform / TouchProfileStorage | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func rowIndex(for letter: UInt8) -> Int? {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated enum KB {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func subCost(_ intended: UInt8, _ typed: UInt8) -> Double {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func grid(for letter: Character) -> (Double, Double)? {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func subCost(_ intended: UInt8, typed: UInt8, tap: KeyTap?) -> Double {` | CPP_CORE / search / SpatialModel | Preserve existing coverage, ordering, costs, limits and score conventions. |

### `keyboard/Engine/TeluguComposer.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Engine/TeluguLexicon.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Engine/TenglishTransliterator.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Engine/Trie.swift` — planned CPP_CORE

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `nonisolated struct Candidate { let word: String; let cost: Double; let logFreq: Double }` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated final class PriorNode {` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func child(_ ch: UInt8) -> PriorNode? {` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated final class TrieSearchPrior {` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private init(funded: [(word: String, bonus: Double)]) {` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func rootChild(_ ch: UInt8) -> PriorNode? { root.child(ch) }` | CPP_CORE / search / SearchFunding | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `nonisolated final class Trie {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private final class Node {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func firstLetterPenaltyPolicy(` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func insert(_ word: String, freq: Int, id: Int32 = -1) {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func node(for word: String) -> Node? {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func contains(_ word: String) -> Bool { node(for: word)?.word != nil }` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func hasPrefix(_ prefix: String) -> Bool { node(for: prefix) != nil }` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func wordID(_ word: String) -> Int32? {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func bump(_ word: String) {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func logFreq(_ word: String) -> Double? {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func search(_ typed: String, maxCost: Double, taps: [KeyTap?]? = nil,` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private static func recurse(_ node: Node, _ letter: UInt8, _ prevLetter: UInt8,` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `func completions(prefix: String, limit: Int) -> [Candidate] {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func collect(_ node: Node, _ out: inout [Candidate], cap: Int) {` | CPP_CORE / search / MutableLexicon | Preserve existing coverage, ordering, costs, limits and score conventions. |

### `keyboard/Engine/UserModel.swift` — planned SWIFT_IOS

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `final class UserModel {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private struct LearnEvent { let context: [String]; let word: String }` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `init(storageURL: URL? = nil) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func uniCount(_ w: String) -> Int {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func uniBackoff(_ w: String) -> (count: Int, total: Int, distinct: Int) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func biLookup(_ p: String, _ w: String) -> (count: Int, total: Int) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func triLookup(_ key: String, _ w: String) -> (count: Int, total: Int) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func biDist(_ p: String) -> [String: Int] {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func triDist(_ key: String) -> [String: Int] {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func topUnigrams(_ limit: Int) -> [String] {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func unigramsSnapshot() -> [String: Int] {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func spellingConfirmationCount(_ word: String) -> Int {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func contextDiversity(for word: String, stoppingAt limit: Int = 2) -> Int {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func confirmSpelling(_ word: String) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func pruneIfNeeded() -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func pruneLocked() -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func prune(_ table: inout [String: [String: Int]], totals: inout [String: Int]) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func storeURL(for epoch: UInt64) -> URL? {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func learn(context ctx: [String], word lw: String) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func demote(_ lw: String) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func decrement(_ table: inout [String: Int], key: String) -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func decrementNested(_ table: inout [String: [String: Int]],` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private nonisolated struct Snapshot: Codable {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func load() {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private enum StoreError: Error { case invalidShape }` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func install(_ m: Snapshot, current: UInt64, migratedLegacy: Bool) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func sanitize(_ table: [String: [String: Int]]) -> [String: [String: Int]] {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func isValidWord(_ word: String) -> Bool {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func save() {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func reset(to epoch: UInt64 = KBPersonalData.currentEpoch) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `func waitForPendingIO() { ioQueue.sync {} }` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |
| `private func clearLocked(epoch: UInt64) {` | SWIFT_IOS / platform / IOSPlatform | Retain the Swift boundary, persistence and platform behavior; export immutable snapshots where the portable core needs data. |

### `keyboard/Shared/KBClipboard.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBDiagnostics.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBKlipy.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBMediaCache.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBPersonalData.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBSafetyLexicon.swift` — planned SPLIT

| Existing declaration (first line) | Planned destination / stage / target | Responsibility |
| --- | --- | --- |
| `final class KBSafetyLexicon {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |
| `enum Action: UInt8 { case allow = 0, demote = 1, suppressSuggest = 2, suppressAlways = 3 }` | SWIFT_IOS / platform / SafetyNormalization | Preserve current Unicode normalization, case/width folding and every action/language rule. |
| `enum Language: UInt8 { case english = 1, telugu = 2, tenglish = 3 }` | SWIFT_IOS / platform / SafetyNormalization | Preserve current Unicode normalization, case/width folding and every action/language rule. |
| `static func bundled(name: String = "safety") -> KBSafetyLexicon? {` | SWIFT_IOS / platform / SafetyNormalization | Preserve current Unicode normalization, case/width folding and every action/language rule. |
| `init?(url: URL) {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |
| `private static func hash(_ s: String) -> UInt64 {` | CPP_CORE / search / SafetyLookup | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `static func normalize(_ value: String) -> String {` | SWIFT_IOS / platform / SafetyNormalization | Preserve current Unicode normalization, case/width folding and every action/language rule. |
| `private func entryHash(_ i: Int) -> UInt64 {` | CPP_CORE / search / SafetyLookup | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func entryTerm(_ i: Int) -> String {` | CPP_CORE / search / SafetyLookup | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func entryAction(_ i: Int) -> Action {` | CPP_CORE / search / SafetyLookup | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func entryLanguage(_ i: Int) -> Language? {` | CPP_CORE / search / SafetyLookup | Preserve existing coverage, ordering, costs, limits and score conventions. |
| `private func matchingIndex(for word: String) -> Int? {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |
| `func action(for word: String) -> Action {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |
| `func language(for word: String) -> Language? {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |
| `func isBlocked(_ word: String) -> Bool {` | SPLIT / search / SafetyLookup | SWIFT_IOS preserves resource loading and Unicode normalization; CPP_CORE validates/queries a lifetime-safe immutable normalized lookup view. |

### `keyboard/Shared/KBSettings.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/KBStats.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/LanguagePackHealth.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Shared/UIColor+Hex.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/ClipboardPanel.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/Emoji.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/KeyButton.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/Keyboard.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/KeyboardLayout.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/KeyboardTheme.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/MediaPanel.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.

### `keyboard/Views/SuggestionBar.swift` — planned SWIFT_IOS

All declarations inherit the file-level SWIFT_IOS ownership.
