# GRU Search-Prior Integration — Walkthrough

_Branch: `gru-integration` (off `main`). Status: **seam implemented + wiring tested; the
streaming/scoring/prior math is verified against the PyTorch checkpoint (`tools/lm`); AND the Core ML
runtime is now verified on the iOS Simulator — the single-step and batched models, scored through the
real Swift `GRULanguagePrior`, match the PyTorch reference within fp16 tolerance (`gruCoreMLScoresMatchPyTorchReference`,
`gruBatchedCoreMLScoresMatchReference`). Remaining unknown is on-physical-device ANE latency/energy.**_

This documents exactly what was built, where, how the decode path uses it, what is and
isn't verified, and the remaining steps to make it live and measurable.

---

## 0. Refinement pass — drive the GRU as a GRU, not a stateless transformer

The first cut drove the GRU like a stateless model, discarding the one property it was chosen for
(cheap incremental state). This pass fixes that and separates the two neural roles. All changes are
fail-safe (production fills neither neural slot) and compile under default **and** `-D INTERNAL_GRU`.

| # | Change | Where | Verified |
|---|---|---|---|
| 1 | **Persist recurrent state across word boundaries.** `runContext` caches `(tokens, state)` and threads only the divergent suffix when the context grows (a committed word), instead of re-running ≤12 words from zero every pass. | `GRULanguagePrior.runContext` | Python: incremental == full rebuild, drift **0.0** |
| 2 | **`memcpy` state copies.** `duplicate`/`zeroState` bulk-copy the fp32 state instead of boxing an NSNumber per float (512/candidate). | same file | trivial; compiles |
| 3 | **First-piece admission filter.** One shared step off the context state scores every candidate's first piece at once; single-piece words are then EXACT (0 extra steps), and only multi-piece candidates whose first-piece upper bound can still reach the top-K are threaded. | `streamScore` | Python: bound holds (0 violations); threshold admission == full top-16 (0 mismatches) |
| 4 | **Prefix-aware, probability-weighted trie prior.** The beam's log-probs (previously discarded) fund the trie bonus by softmax (peaked→narrow+deep, flat→broad+shallow); once the word is ≥3 chars, generation is constrained to word-starts spatially reachable from the first tap. | `TrieSearchPrior(scoredWords:)`, `generateNextWords(firstLetters:)`, `contextSearchPrior` | Python funding demo + `trieSearchPriorProbabilityWeightingFundsByConfidence` |
| 5 | **Split the neural contract into two roles.** `searchPrior: NeuralSearchPrior` (recall/generation) and `rescorer: NeuralLanguagePrior` (precision) are independent slots — choosing one no longer evicts the other. | `DecodeContract.swift`, `KeyboardEngine` | wiring tests |
| 6 | **Score OOV / user-adopted words.** The search-prior pool is seeded with the user's adopted next-words (`contains && !isStaticWord`) that `NgramScorer.nextWords` drops, so the GRU can rank them by P(word\|context). | `userAdoptedNextWords`, `contextSearchPrior` | compiles; wiring |
| 7 | **Unify glide + centralize blend.** The GRU's cached next-words feed glide's rerank pools; `0.7·neural+0.3·ngram` becomes the named `neuralPriorWeight`. | `neuralNextWords`, glide augmenters | compiles |

Net effect on the scoring hot path: the old per-candidate-per-token cost (`≈ candidates × (context + word)` sequential Core ML steps, twice per warm) collapses to `≈ context-suffix + 1 + Σ(admitted pieces − 1)`, and the context suffix is usually one word (state persisted).

### Follow-up pass — A (runtime verification), B (context), C (batched export)

| | Change | Where | Verified |
|---|---|---|---|
| **A** | **Core ML RUNTIME parity on the simulator.** The real `GRULanguagePrior` (compiled from `gru.mlpackage`) scored on the sim's Core ML runtime matches the PyTorch reference within fp16 tol — shapes, `token`/`state_in`/`logits`/`state_out` names, persisted state threading, and `gru_tokenizer.bin` all validated end-to-end. | `gruCoreMLScoresMatchPyTorchReference` (keyboardTests) | ✅ passes on simulator (Δ < 1 nat over 1–5-piece words) |
| **B** | **Context is already sentence-scoped.** The controller's `contextWords` stops at `.!?\n` and caps at 8 words, which matches the GRU's measured effective memory (next-word distribution stops moving by ~6–8 words). The engine's redundant `suffix(12)` is now the named `neuralContextWordCap = 8`, in sync with the controller. | `contextWords` (KeyboardViewController), `neuralContextWordCap` | measured (tools/lm context-length TV) |
| **C** | **Batched `[B,T]` scorer.** `export_gru_score_coreml.py` → `gru_score.mlpackage`: one Core ML call scores the whole candidate pool (context state threaded once, broadcast across the batch, gathered at candidate positions) instead of per-candidate threading. `GRULanguagePrior` loads it optionally and `streamScore` dispatches to `batchScore` when present (single-step generation + fallback unchanged). | `GRUBatchScore` (tools/lm), `batchScore` (GRULanguagePrior), `install_internal_gru.sh` | module == streamScore Δ≈5e-6; Core ML runtime parity on sim (`gruBatchedCoreMLScoresMatchReference`) |

So the scoring path now has two verified implementations: single-step (persisted state + first-piece admission, no extra model) and batched (one call, needs `gru_score.mlpackage`). The remaining perf work is a physical-device ANE latency/energy measurement.

---

## 1. What this branch adds

The GRU is wired in as a **`NeuralLanguagePrior`** — the same protocol the transformer
rescorer already uses — so it inherits the engine's proven ranking blend, per-word tier
freeze, and memory handling instead of a second ranking path.

| Change | File | What |
|---|---|---|
| New tier | [DecodeContract.swift](keyboard/Engine/DecodeContract.swift) | `DecodeModelTier.neuralGRU` |
| The prior | [CoreMLNeuralLanguagePrior.swift](keyboard/Engine/CoreMLNeuralLanguagePrior.swift) | `GRULanguagePrior` (appended; reuses the file-private `KeyboardSentencePieceTokenizer`) |
| Selection | [Keyboardengine.swift](keyboard/Engine/Keyboardengine.swift) | `KeyboardEngine.shared` picks it behind `#if INTERNAL_GRU` |
| Test | [keyboardTests.swift](keyboardTests/keyboardTests.swift) | `gruSearchPriorTierBlendsIntoRanking` |
| Export | [export_gru_coreml.py](tools/lm/export_gru_coreml.py) | `forward_step` → Core ML (run on Colab) |

**Fail-safe:** with no bundled `gru.mlpackage`/`gru_tokenizer.bin`, `isReady` stays `false`,
`preferredModelTier` returns `.ngram`, and the engine behaves exactly as `main`. Nothing
ships until the model is present. `INTERNAL_GRU` is off by default.

---

## 2. How the decode path uses it (the walkthrough)

`GRULanguagePrior` conforms to this seam ([DecodeContract.swift](keyboard/Engine/DecodeContract.swift)):

```
protocol NeuralLanguagePrior {
  var modelTier: DecodeModelTier { get }      // .neuralGRU
  var isReady: Bool { get }                    // model loaded?
  func prepareContext(_ words: [String], wordSessionID: UInt64)
  func score(candidates: [String], wordSessionID: UInt64, completion: (Result<[String:Double],Error>)->Void)
  func discardSession(_ wordSessionID: UInt64)
  func prepareForSelection(); func handleMemoryPressure()
}
```

Per keystroke, inside `KeyboardEngine`:

1. **Tier freeze (word boundary).** `preferredModelTier(for: .english)` returns
   `neuralPrior.modelTier` (`.neuralGRU`) iff the prior `isReady` and `KBSettings.neuralEnabled`.
   The tier is frozen for the whole word session — no mid-word fallback.
2. **Context prep (once/word).** `GRULanguagePrior.prepareContext` tokenizes the last ≤12
   context words (with the `<en>` mode token) and caches them as `Session.contextTokens`
   keyed by `wordSessionID`.
3. **Generate.** The trie/spatial DP produces the candidate pool exactly as today (n-gram
   path unchanged). **This is the key limitation of *this* layer — see §4.**
4. **Score (async, off the hot path).** `rank()` calls `score(candidates:)`. `GRULanguagePrior`
   on its own queue:
   - rebuilds the recurrent state by threading `contextTokens` through `forward_step`
     (`runContext`),
   - for each candidate word, **duplicates** that context state and threads the word's
     SentencePiece tokens, summing `log-softmax(logits)[token]` → `log P(word | context)`,
   - returns `[candidate: logProb]`.
5. **Blend.** The engine folds each candidate's `neuralLogProbability` into `rawScore`
   alongside `−spatialCost + lmWeight·logP_ngram + freqWeight·logFreq` — the existing,
   tested blend. The autocorrect margin gate then reads the blended scores.
6. **Cleanup.** `discardSession` on word advance; `handleMemoryPressure` drops the model.

The letter-insert path never touches any of this — it stays fire-on-touch. All GRU work is
async on `keyboard.neural.gru`, and a superseded pass bails on the generation ticket.

---

## 3. What's verified vs unverified

**Verified (75/75 tests):** the *wiring*. `gruSearchPriorTierBlendsIntoRanking` drives a
mock `.neuralGRU` prior through a real `decode()` and asserts the engine selects the tier,
calls `prepareContext` once, `score` on the pool, and attaches a `neuralLogProbability` to
every candidate. The blend, tier freeze, and memory paths are the same ones the transformer
already exercises.

**Unverified (and honestly cannot be, yet):** the Core ML forward pass in `GRULanguagePrior`
(`step`/`streamScore`). It compiles against the generic `MLModel` API, but its numbers can
only be checked once `gru.mlpackage` is exported (coremltools, Colab) and bundled, on a real
device. Until then it never loads a model, so it's inert.

---

## 4. Two layers — both now implemented

- **Layer 1 — rescorer.** The neural prior scores the candidate list and blends into ranking. Now
  its OWN contract slot (`rescorer: NeuralLanguagePrior`), independent of the search prior — the
  transformer's job. Redundant for the GRU; kept only as the tested seam.
- **Layer 2 — NN-LM IN the trie (context-aware generation).** ✅ **Implemented.** A
  `TrieSearchPrior`, built from the LM's likely next words, funds extra edit budget along
  those words' prefixes *inside* the trie walk — so a context-plausible word just outside the
  fixed edit radius is **generated**, not merely re-ranked. This is the piece that attacks the
  ~85.6% oracle-recall ceiling.
  - **Where:** `TrieSearchPrior` + threaded through `Trie.recurse` ([Trie.swift](keyboard/Engine/Trie.swift))
    **and** the mmap production walk `LangData.trieSearch` ([LangData.swift](keyboard/Engine/LangData.swift)),
    byte-identical to before when the prior is `nil`.
  - **Scope:** wired into the **recovery** search (`broadCorrections`) via
    `KeyboardEngine.contextSearchPrior`, *not* the close search. Rationale — proven live: a
    prior on the close search dragged "sebd" → "see" over the spatially-correct "send"
    (`looseCandidatesCannotBeatCloseChannelMatches`). The recovery pool already rides the
    channel-dominance guards, which keep the rescue honest.
  - **Prior source:** the shipped **n-gram**, now UNIONED with the GRU's **generated**
    next-words. `GRULanguagePrior.warmSearchPrior` runs a bounded subword beam
    (`generateNextWords`) that decodes the GRU's own likely next-words — including words the
    sparse bi/trigram tables never proposed — unions them with `ngram.nextWords`, ranks the
    whole set by the GRU, and caches it; `contextSearchPrior` then keeps the ones the lexicon
    can emit. This is **generation, not reranking**: it attacks the n-gram's next-word recall
    ceiling, which reranking a fixed pool could not. Reference + validation:
    [tools/lm/generate_next_words.py](tools/lm/generate_next_words.py) (the Swift beam mirrors
    it step for step against `gru.pt`).
  - **Test:** `trieSearchPriorExpandsContextPlausibleWords` proves a word outside the base
    radius is generated, at its true channel cost, without fabricating unfunded words.

  *Honest scope:* the beam generates whole **words** (a word-prefix-funded budget expansion,
  shipping-safe). A full per-**character** neural beam threaded node-by-node through the trie,
  pruning by a joint spatial+neural score, is the further step; it needs a char-level model.

---

## 5. Remaining steps to make it live + measurable

1. **Export the model on Colab** (coremltools): `python export_gru_coreml.py` → `gru.mlpackage`.
   *(Design note: DONE. §0 cut the per-token overhead (persisted context state + first-piece
   admission on the single-step export), and the follow-up pass added the **batched** score export —
   `export_gru_score_coreml.py` → `gru_score.mlpackage`, context + candidate tokens → per-candidate
   log-probs in one call. `GRULanguagePrior.batchScore` uses it when bundled; both paths are Core ML
   runtime-verified on the simulator. Physical-device ANE latency/energy is the only measurement left.)*
2. **Bundle** `gru.mlpackage` (or compiled `gru.mlmodelc`) + `gru_tokenizer.bin` (a `tokenizer.bin`
   built from `qwen_spm.model`) into the extension target; add a `validate()` interface check
   like the transformer's.
3. **Build with `-D INTERNAL_GRU`**, verify Core ML == PyTorch on device (extend the export's
   parity check), and confirm `isReady` flips true.
4. **Before/after measurement** (finally possible): with `INTERNAL_GRU` on vs off, on the
   tricky-input battery — corrections/suggestions diff + tap-decode p95 + peak RAM. Batched
   scoring keeps a ~100-candidate pool near ~2 ms (the `--benchmark` figure), well inside the
   75 ms budget; measure it for real.
5. Then start **Layer 2** on top.

---

## 6. Design decisions

- **Conform to the existing seam, don't fork the ranker.** Reuses proven blend/tier/memory
  code; the GRU is a drop-in alternative to the transformer prior.
- **Appended to `CoreMLNeuralLanguagePrior.swift`, not a new file.** Avoids a hand-edited
  `project.pbxproj` (a real build-breakage risk) and reuses the file-private tokenizer.
- **Explicit recurrent state I/O in the export** (not a managed Core ML `StateType`): the
  Layer-2 decoder must branch state across beam paths, which a single managed state can't.
- **Fail-closed everywhere:** missing model/tokenizer/session → n-gram. The branch cannot
  regress `main`.

---

## 7. Current numbers (context)

Fine-tuned GRU (`tools/lm/data/gru.pt`, 2.33M): messaging **top-1 21.7% / word-initial 21.3%**,
streaming parity ~1e-6. `forward_step`: ~266 µs single / ~20–26 µs per candidate batched
(PyTorch-CPU; ANE faster). Distillation to be re-run with the fixed recipe for the shipping
checkpoint — the export/integration here is checkpoint-agnostic.
