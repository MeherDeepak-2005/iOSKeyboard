# GRU Search-Prior Integration — Walkthrough

_Branch: `gru-integration` (off `main`). Status: **seam implemented + wiring tested; Core ML
forward pass unverified until the model is exported & bundled.**_

This documents exactly what was built, where, how the decode path uses it, what is and
isn't verified, and the remaining steps to make it live and measurable.

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

## 4. Two layers: this is the rescorer, not yet the in-trie search

- **Layer 1 — rescorer (this branch).** The GRU scores the candidate list the trie already
  produced, and the score is blended into ranking. This improves *ordering* and the
  autocorrect decision. It does **not** change which candidates exist.
- **Layer 2 — LM-in-the-loop trie search (next, larger).** To close the ~85.6% oracle-recall
  ceiling, the GRU must guide *generation*: score partial paths during `Trie.recurse` /
  `IncrementalDecodeSession` and keep/prune branches by a joint `channelCost + λ·(−logP_GRU)`.
  This is where the GRU's O(1) streaming state and the **single-step** `forward_step` export
  pay off (branch the state across the beam frontier). It rewrites the core walk and is its
  own milestone — deliberately not faked here.

---

## 5. Remaining steps to make it live + measurable

1. **Export the model on Colab** (coremltools): `python export_gru_coreml.py` → `gru.mlpackage`.
   *(Design note: `score(candidates:)` per-token prediction has call overhead. For the
   rescorer, add a **batched** score export — context + candidate tokens → per-candidate
   log-probs in one call, like the transformer's `KeyboardInferenceModel` — and point
   `GRULanguagePrior` at it. The single-step export is for Layer 2.)*
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
