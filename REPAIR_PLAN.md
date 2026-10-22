# Keyboard decoder repair plan

## Recommended main branch

Use remote `main` as the canonical product branch. At the analysis baseline,
`origin/main` (`8c12323`) and `origin/gru-integration` (`b9ae208`) have identical file
trees: main already contains the GRU work through the merge. There is no additional
implementation to gain by choosing the GRU branch instead.

The newer implementation has the most potential: it combines the mapped lexicon,
incremental spatial search, versioned decode snapshots, personalization, language
packs, release checks, and an optional neural generation interface. Preserve these
foundations while repairing the search integration.

Keep production defaults n-gram-only until the neural path passes the gates below.
Develop repairs in focused branches based on the canonical main, then merge validated
changes back. Use `codex/` prefixes for branches created by Codex.

**Local checkout caveat:** the checked-out `main` is `24e93a1`, with nine commits
unique to local main and thirty unique to remote main. This plan targets the newer
remote tree, not the old local source. Before implementing it, inspect the unique
commits and preserve any work that remains valuable. Do not reset the local branch
or blindly pull across this divergence. A fresh branch/worktree from remote main
is a suitable implementation starting point.

## Analysis baseline and limits

- Reviewed the remote branch tips, relevant implementation history, and Google's
  published [Neural Search Space in Gboard Decoder](https://aclanthology.org/2024.emnlp-industry.93.pdf).
- Default simulator build succeeded; all 81 existing Swift unit tests passed.
- Fifteen top-level Python tests, four replay-report tests, and two tokenizer-export
  tests passed.
- Executable Swift probes reproduced broad-recovery omissions, shortlist confidence
  normalization, and funding leakage to shorter terminal words.
- GRU/Core ML model parity and physical-device performance were not verified:
  the necessary model artifacts and ML dependencies were absent.
- Language-pack Python tests could not run without `requests`.

The comparison concerns Google's published 2024 design, not access to its current
proprietary source. Matching its LSTM architecture is not required. The important
goals are correct candidate coverage, consistent neural scores, bounded inference,
and hypothesis-conditioned search.

## Target behavior

1. Normal spatial search retains its existing candidate coverage and costs.
2. Broad recovery remains complete for its advertised radius.
3. A ready neural prior demonstrably introduces candidates that baseline generation
   misses, and its exact score influences selection.
4. Search and ranking use the same complete-word probability definition.
5. Stale work cannot publish across request, personalization, or model epochs.
6. Neural failure, absence, or opt-out preserves a tested baseline path.
7. Suggestions and boundary corrections continue to use the same validated snapshot.

## Phase 1 — repair candidate generation before changing the model

### P1: connect the prior to the actual recovery path

**Files:** `keyboard/Engine/Keyboardengine.swift`, `LangData.swift`, `Lexicon.swift`.

**Problem:** recovery prefers `retained.candidates(...)`. That method accepts no
prior, so a valid incremental session bypasses `broadCorrections(... prior: ...)`.
The length requirements overlap: retention begins at five characters, while broad
recovery starts at six.

**Implementation:** keep retained search for the normal radius. Initially use the
full mapped-trie search for broad recovery, with the prior supplied explicitly.
Add cooperative cancellation and preserve the existing channel-dominance guard.
Do not optimize this path again until equivalence and neural contribution are tested.

**Acceptance:**

- Inject a deterministic `NeuralSearchPrior` into an engine using a fixture language
  pack. Show that a funded, otherwise unreachable word enters the recovery pool.
- Exercise lengths six and above with an active retained session.
- Test nil, unavailable, ready, and failed prior states independently.
- Verify that baseline candidates keep their original spatial costs.
- Record whether a decode used neural funding, n-gram funding, or no funding.

### P1: restore broad-radius completeness

**Problem:** `incrementalSeeds` selects root branches for the normal radius of 3.6.
The engine reuses those seeds for recovery at twice the normal budget. A larger
final threshold cannot recover words removed during seed selection.

**Reproduction:** with the shipped pack and no touch offsets, full trie search at
7.2 finds `correction` for `qorrection`; retained search does not.

**Implementation:** the full recovery walk above is the initial correctness fix.
If incremental recovery is later introduced, build seeds for its actual radius and
maximum prior allowance. Fall back to full search whenever a state cap prevents a
complete seed set. Never silently truncate the search domain.

**Acceptance:** compare candidate sets and costs against full search across all
initial letters, insertion/deletion/transposition cases, and touch-offset cases.
Include `qorrection`, state-cap fallback, and prior-expanded budgets. Retain the
existing normal-radius equivalence tests separately.

## Phase 2 — make probabilities and pruning consistent

### P1: define one complete-word score

**Files:** `keyboard/Engine/GRULanguagePrior.swift`,
`tools/lm/generate_next_words.py`, `tools/lm/export_gru_score_coreml.py`.

**Problem:** generation includes a word-boundary probability; `rankPool` rescoring
removes it by summing only candidate-piece probabilities. The single-step fallback
also exposes uncomputed candidates' first-piece upper bounds as ordinary scores.

**Implementation:** define and document the canonical score as the sum of piece
log probabilities plus the log probability of ending the word. Use that definition
in generation, single-step scoring, batch scoring, and the Python reference.
Represent upper bounds separately from exact scores. Compute an exact score before
funding or publishing a candidate, or omit it through explicit, justified pruning.

**Acceptance:**

- Compare Python, Swift single-step, and Swift batch scores on the same checkpoint,
  tokenizer, context, and candidates, including one-piece and multi-piece words.
- Include a fragment whose continuation probability is high.
- Exercise more than sixteen candidates to cover admission pruning.
- Assert that every published `SearchPriorWord.logProbability` is an exact score
  under the documented scoring convention.
- Check that changing the optional batch model does not change the candidate set
  or ranking beyond the declared numerical tolerance.

### P2: correct funding confidence and terminal leakage

**Files:** `keyboard/Engine/Trie.swift`, `LangData.swift`.

**Problems:** shortlist softmax discards absolute probability mass. A singleton at
log probability -100 gets the same 1.6 bonus as one at -0.1. Shared prefix bonuses
also allow a funded longer word to fund an unfunded shorter terminal word.

**Implementation:** distinguish traversal bounds from terminal-word funding.
Store explicit terminal funding; prefix bounds may guide traversal but must not
automatically authorize terminal emission. Either replace bonuses with weighted
LM search costs, or define a bounded, calibrated funding function that retains
absolute probability information. Treat the existing top-word floor as an explicit
heuristic requiring evaluation, not evidence of model confidence.

**Acceptance:**

- Test singleton scores -0.1 and -100 and a shortlist shifted downward by a constant.
- Funding `cart` must not grant terminal funding to `car` unless `car` is also funded.
- Shared prefixes remain traversable for legitimately funded descendants.
- Nil prior reproduces baseline output; funded paths retain true spatial costs.

### P1: preserve neural evidence through final selection

**Files:** `keyboard/Engine/Keyboardengine.swift`, `DecodeContract.swift`.

**Problem:** `INTERNAL_GRU` installs only a search prior. Final ranking normally
uses n-grams, and spatial/frequency shortlist caps can remove neural candidates
before their neural evidence affects selection.

**Implementation:** carry exact neural scores and source evidence with generated
candidates. Define a consistent combined spatial/LM objective and use it for
candidate admission and final ranking. Keep the typed row and safety policies.
Evaluate interpolation on a separate development set. The design is a neural
search space: there is no second rescoring model, and the transformer rescorer
has been removed.

**Acceptance:** an engine-level test must demonstrate generation and selection
with only the GRU search role configured. Add an ablation where a neural candidate
would be removed by the old spatial/frequency cutoff. Verify suggestions and
boundary decisions still agree.

### P2: remove accidental shortlist losses

**Files:** `keyboard/Engine/GRULanguagePrior.swift`, `Keyboardengine.swift`.

- Apply legal-token/first-letter constraints before selecting top beam extensions.
  Test a compatible token ranked below the original global top eight.
- Validate dictionary membership during generation or before the final word limit.
  Invalid fragments must not consume all available valid-word slots.
- Preserve explicitly seeded adopted words when the n-gram pool already has 24 words.
  Ensure the relevant mutable lexicon layer can actually emit those words.
- Score unions larger than the 32-row batch in multiple chunks; do not silently
  discard the tail. Test pools of 33 and 48 words.
- Either implement full typed-prefix spatial compatibility or name the current
  constraint accurately as a first-letter constraint.

## Phase 3 — bound inference and protect cache lifecycle

### P2: add cancellation, epochs, and readiness semantics

**Files:** `keyboard/Engine/GRULanguagePrior.swift`,
`Keyboardengine.swift`, `DecodeContract.swift`.

**Problems:** per-key deduplication does not bound queued prefix work. Cache keys
omit first-letter constraints and personalization revisions. In-flight work can
repopulate cleared caches. Completion does not request a refreshed decode.

**Implementation:**

- Coalesce obsolete prefix jobs and check cancellation between beam steps.
- Add model and personalization epochs; reject stale load and inference completions.
- Include all inputs affecting output in cache identity: context, language/register,
  constraints, seed-pool revision, and relevant epochs.
- Clear retained state and prevent stale repopulation on reset or memory pressure.
- Provide a readiness notification that requests a new revision-validated decode
  only if its word session remains current. Never alter an already committed word.
- Make the neural preference's effect on both roles explicit and tested.
- Add cold/warm latency, cache hit rate, queue depth, cancellation count, prior-use,
  and fallback diagnostics. Keep raw text out of production diagnostics.

**Acceptance:** rapid typing/backspacing must leave bounded pending work. Tests
must cover reset during inference, pressure during loading, changed first-tap
constraints, changed adopted vocabulary, and completion after a field switch.

## Phase 4 — close the multiword search gap

### P2: decode hypothesized boundaries with recurrent state

**Files:** `keyboard/Engine/Keyboardengine.swift`, `DecodeContract.swift`,
`GRULanguagePrior.swift`.

**Problem:** `splitCandidate` selects one exact dictionary pair. It does not retain
competing segmentations, correct both component words jointly, or condition neural
continuations on each uncommitted first-word hypothesis.

**Implementation:** introduce bounded search hypotheses containing the spatial
state, lexicon position, hypothesized words, LM state, and accumulated score.
At a plausible boundary, branch the recurrent state and score continuations using
committed context plus hypothesized words. Prune by the combined objective. Preserve
literal and unigram fallback for words absent from the neural shortlist.

Start with two-word decoding. Extend to three-word cases only after latency and
memory remain acceptable. This can use a weighted graph or an equivalent explicit
beam; changing the recurrent cell alone does not address this gap.

**Acceptance:** cover missing spaces, substituted spaces, competing boundaries,
typos in either component, three joined words, rare words, and no-boundary input.
Compare against the existing split heuristic and retain correct-input safeguards.

## Phase 5 — make artifacts and measurements trustworthy

### P1: enforce export parity and correct benchmark units

**Files:** `tools/lm/export_gru_coreml.py`, `export_gru_score_coreml.py`.

- Fail export with a nonzero exit status when parity exceeds its declared tolerance.
  Do not save a supposedly verified artifact after printing `FAIL` or `HIGH`.
- Check exported recurrent state as well as logits, including multi-step threading,
  branching from the same state, and reconverging equivalent contexts.
- Correct the one-millisecond projection to `1000 / microseconds_per_step`.
  At 100 microseconds per step, the answer is ten steps, not ten thousand.
- Label PyTorch CPU timing as a development measurement, not iPhone Core ML latency.
- Validate model input/output shapes against configuration and tie checkpoint,
  tokenizer, export configuration, and model packages together with hashes.

### P1: add missing integration evaluation before promotion

**Files:** `keyboardTests/keyboardTests.swift`, `tools/evaluation/`,
`tools/lm/benchmarks/`.

The engine tier test now installs the model as a search prior, matching the
default internal GRU configuration. Direct trie tests do not establish that
the engine uses neural recovery. The committed transformer results are not evidence
for the new GRU generation path.

Create an explicit evaluation matrix:

| Configuration | Purpose |
|---|---|
| N-gram baseline | Stable product reference |
| N-gram-funded recovery | Isolate trie-budget heuristic effects |
| GRU generation with baseline ranking | Measure generation recall independently |
| GRU generation with consistent neural ranking | Measure the complete neural path |

Use a development split for tuning and an untouched, user-separated blind test set.
Include already-correct input, real-word typos, severe typos, rare/personal words,
space errors, sentence starts, contractions, and supported language modes.
Do not force the expected answer into generated candidate pools.

Report oracle recall before and after every cap, top-1/top-3, false-correction rate,
suggestion/commit agreement, and results by error slice. On a physical iPhone, report
cold/warm p50/p95/p99, peak memory, queue growth, thermal/energy behavior, and bundle
size. Declare acceptance thresholds before examining blind results.

### P2: make multilingual scope match runtime behavior

**Files:** `tools/lm/multilingual/README.md`, `GRULanguagePrior.swift`,
`Keyboardengine.swift`, language-pack builders.

The mixed-corpus pipeline is groundwork, not a completed multilingual decoder.
The neural path currently uses English conditioning, alphabetic generation gates,
and lexicon validation that constrain what a mixed checkpoint can emit.

Define supported language/register routing, tokenizer compatibility, dictionary
coverage, and mode-specific constraints. Evaluate each supported register and
code-switch slice separately. Update documentation to distinguish model training
from integrated product support; do not enable new registers solely by swapping
the checkpoint and tokenizer.

## Completion checklist

- [ ] Preserve/reconcile local-only commits before adopting canonical main.
- [x] Fix recovery bypass and broad-radius completeness.
- [x] Unify complete-word scoring; keep bounds separate from exact scores.
- [x] Fix terminal funding and preserve absolute probability.
- [ ] Calibrate funding and decision confidence using held-out data before promotion.
- [x] Preserve neural evidence through pruning and selection.
- [x] Repair constrained beam selection and pool truncation.
- [x] Add cancellation, cache epochs, and safe readiness notifications.
- [x] Add hypothesis-conditioned multiword decoding.
- [x] Enforce export parity and repair benchmark units.
- [ ] Run the full ablation matrix and physical-device promotion gates.
- [ ] Integrate and validate multilingual routing before claiming support.

Implement Phases 1–3 before investing in a larger model or another training run.
They establish whether the existing checkpoint can improve the actual decoder.

## Implementation status — 2026-10-05

Changes are in `codex/decoder-repairs`, based on `origin/main`. The original local
`main` branch is preserved; its divergent commits have not been merged or deleted.
Checked items above are implemented source work. Unchecked items are integration
or promotion work; they are not implied complete by passing plumbing tests.

Implemented in source:

- Full-radius recovery no longer substitutes narrower retained-search results.
  Mapped, supplementary, and personal vocabulary use terminal-specific funding.
- Funding uses a bounded absolute-log-probability ramp. This is a heuristic,
  **not calibrated confidence**; a poor singleton no longer receives maximum funds.
- GRU-only sessions score final candidates and autocorrect decisions with GRU
  evidence. Their pools remain intact until exact neural scoring, then are capped.
- Legal tokens are filtered before beam top-k and dictionary validity before the
  completed-word cap. Every seed is scored; batches chunk beyond 32 and long
  continuations use streaming instead of truncation.
- Streaming and version-2 batch scores include the ending event. Exact scores are
  separated from generation/pruning bounds; legacy batch graphs are rejected.
- Search jobs coalesce to current context/prefix, use true LRU keys including seed,
  constraint and vocabulary identity, and check model epochs and cancellation.
  Readiness callbacks refresh only a matching active request. Memory pressure
  clears state and applies a load cooldown; malformed/non-finite outputs fail.
- An internal GRU beam explores up to three words, including omitted spaces and
  neighboring space-key substitutions. Each expansion scores its entire phrase
  from committed context before pruning, so later words depend on earlier ones.
  This bounded segmentation implementation still differs from Google's packed,
  touch-position and recurrent-state search graph; performance needs measurement.
- Export checks fail on drift, benchmark units are corrected, and manifests and
  reference scores record checkpoint/tokenizer hashes and runtime parity status.
- Aggregate search latency, cache, cancellation and funding diagnostics were added.

Validation completed:

- Full Debug build and **all 88 simulator tests passed** on iPhone 17 Pro / iOS 26.5.
  Result bundle: `/tmp/ioskeyboard-repairs-tests-6.xcresult`.
- Real Core ML streaming and version-2 batched scoring matched a deterministic
  tiny PyTorch model within 0.02 nats for the entire pool exceeding 32 candidates,
  including long-word streaming fallback. Pressure reset/cooldown passed.
- Neural-only ranking and autocorrect, funding beyond the baseline radius,
  retained-search broad recovery, terminal funding, constrained beam selection,
  vocabulary/cache identity and multiword search regression tests passed.
- 23 Python model/export tests and 4 evaluation-report tests passed.
- Standalone Swift multiword checks passed for three-word segmentation, space-key
  substitution and cancellation; the full simulator suite also covers these cases.
- Swift syntax parsing and `git diff --check` passed. Test-generated render changes
  were restored; no unrelated image changes remain.

The credit-related approval failure was resolved after the workspace refill.
Core ML fixture export succeeded with authorized host access; its streaming
logit/state errors were below 0.0000002. These checks establish plumbing parity,
not trained-model prediction quality.

Outstanding:

1. Validate the actual trained GRU artifacts using `INTERNAL_GRU` parity tests
   and their checkpoint/tokenizer sidecars. The tiny random fixture verifies
   runtime plumbing but cannot establish quality or trained-artifact compatibility.
2. Reconcile local-only main commits deliberately before replacing that branch.
3. Run paired, user-separated ablations: shipping n-gram; n-gram funding;
   neural funding; GRU-only ranking; multiword beam.
   Capture oracle recall before/after caps, top-1/top-3, false corrections,
   suggestion/commit agreement, and each error/register slice. No result is claimed.
4. Physical-device latency, peak memory, energy/thermal and jetsam measurements.
5. Integrate new multilingual routing/dictionaries and evaluate code-switch slices
   before enabling them. Current neural scope is explicitly English only.

Release neural defaults remain disabled pending those gates. Repairs are local
changes; no trained model, release promotion, commit, push or merge was performed.


### Custom severe-typo benchmark

`coeevitjkn → correction` was replayed with the actual Swift engine in Release
on the iPhone 17 Pro / iOS 26.5 simulator. Without neural scoring it committed
`correction` in all 155 replays across empty, `auto`, and three recorded live
contexts. The suggestions were `correction`, `coercion`, with correction ranked
first and generated by broad recovery at spatial cost 6.525. Warm p50 was
13.96–15.68 ms; warm p95 was 18.29–23.82 ms. First requests were 101.27–136.59 ms
and include queued engine initialization; synchronous construction occurred
outside the timer. The result is saved in
`tools/evaluation/results/coeevitjkn-simulator.json`.

Trained-neural mode was not run: its model/tokenizer were on another laptop and
are absent here. No random fixture or mocked scores were substituted. This is one
custom benchmark, not population recall or a physical-iPhone measurement.

The optimized build also exposed and fixed Release-only neural diagnostic guards.
The model installer scripts are now declared build-phase inputs so ordinary
Release builds can read them under Xcode's script sandbox.
