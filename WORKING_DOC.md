# Keyboard — Working Doc

_Last updated: 2026-07-22 · branch `main` (bilingual work on `bilingual`)_

Living summary of where this keyboard stands vs the incumbents, what we're building,
and what's holding us back. Primary section is the **comparison report**.

---

## End goals

- A **privacy-first, on-device** English / Tenglish (Roman) / Telugu keyboard for India
  and the Telugu diaspora — no typed text leaves the device, no federated user-data
  dependency.
- **Close the quality gap with Gboard** without user-data training, via:
  1. **LM-in-the-trie** — a streaming neural prior that guides candidate *generation*
     (not just re-ranking). → GRU search prior (in progress).
  2. **Bilingual English+Tenglish** code-switching in one decoder. → Plan 2 (`bilingual`).
  3. **Morphology-aware Telugu** + a compiled transliteration FST.
- Ship input latency at stock parity (already proven: host insert ≤1 ms on device).

---

## Comparison report — This keyboard vs Apple vs Gboard

### Scorecard

| Axis | This keyboard | Apple (iOS 17+) | Gboard | Verdict |
|---|---|---|---|---|
| **UI geometry** | Apple-matched (54 pt row pitch, 6 pt gaps) | reference | tight, +number row | **parity** |
| **UI features** | haptics, themes, language only | dictation, tight | number row, resize, glide, many toggles | **behind** |
| **Backbone (LM)** | Witten–Bell **trigram** (neural = DEBUG only) | on-device **transformer LM** | **NN-LM + Neural Search Space** | **1 gen behind** |
| **Candidate gen** | fixed edit-radius trie → *then* rerank | LM-integrated | **LM-in-FST search** | **behind (recall)** |
| **Dictionary — EN** | 60,450 words | ~250k | larger + web | **medium gap** |
| **Dictionary — Tenglish** | 12k keys, no FST, unknown→literal | n/a | arbitrary-input translit | **large gap** |
| **Dictionary — Telugu** | 22k flat wordlist, no autocorrect | native | full native + translit | **large gap (beta)** |
| **Personalization** | on-device counts + spatial (per-row) | on-device + iCloud sync | federated + per-key | **behind (no sync/federated)** |
| **Speed — insert** | fire-on-touch **≤1 ms** (measured) | same | same | **parity** |
| **Speed — decode** | n-gram fast; neural W8 p95 ≤120 ms (DEBUG) | fast | fast | **parity (n-gram)** |

### The details that matter

**Backbone (the #1 gap).** Production ranking is a Witten–Bell *interpolated trigram*
(`NgramScorer`). The 10.6M transformer rescorer (`CoreMLNeuralLanguagePrior`) is wired
**DEBUG/INTERNAL_NEURAL only** — Release ships n-gram. Worse, candidate generation is
*generate-then-rerank*: a fixed weighted-edit-distance trie walk produces candidates,
then the LM re-orders them. Anything outside the edit radius is **never generated**, so
the LM can't rescue it — the two-edit **oracle recall ceiling is ~85.6%**. Apple runs an
on-device transformer LM for autocorrect; Gboard folds an NN-LM **into** the FST decoder
(Neural Search Space) so the LM guides the *search*, not just the ranking.

**Dictionary.** English 60,450 words (SCOWL/ESDB validity + OpenSubtitles frequencies +
Tatoeba n-grams) — decent coverage, narrow register, ~4× smaller than Apple. Tenglish is
a 12k-key lookup (628 bigram contexts), **not a compiled FST**, so unknown Roman input
stays literal — Google transliterates arbitrary input. Telugu is a **flat 22k wordlist**
with tiny context tables and no autocorrect — fundamentally mismatched to an agglutinative
language (inflected forms explode; a fixed list can't cover them).

**Speed.** The input path is genuinely stock-grade — fire-on-touch, host insert **≤1 ms
measured on device**, all decode async off the hot path. The neural tier costs latency
(tap-decode p95 in the 75–120 ms band with W8) and memory (**57.7 MB peak, DEBUG+neural**,
near the jetsam edge) — both are promotion blockers, both fixable (progressive
enhancement + device-tiered W8A8 + measure the n-gram-only floor).

---

## What's holding us back (architecture / techniques)

1. **Trigram n-gram in production** where the incumbents ship neural LMs. One generation
   behind on the model itself.
2. **Generate-then-rerank** instead of **LM-in-the-loop search**. This is the real ceiling:
   reranking can't recover a candidate the trie never generated (oracle recall ~85.6%).
3. **Flat wordlists** — no morphology model for Telugu, no compiled weighted FST for
   Tenglish. Both cap coverage far below Gboard.
4. **No federated / user-data learning** (deliberate privacy trade-off, but it's where
   Gboard's years of data give it an edge we must close structurally, not with data).
5. **Neural not promotable yet** — latency (~120 ms p95) + memory (57.7 MB) gates unmet.

---

## Prioritized improvements

| # | Item | Fixes | Status |
|---|---|---|---|
| 1 | **GRU in-trie search prior** (2.3M, streaming) distilled from the 10.6M teacher | recall ceiling + neural promotion (small, streaming, ANE-friendly) | pipeline built; training on Colab |
| 2 | **Bilingual EN+Tenglish** merged-pool decoder (parallel, calibrated scores, language prior) | code-switching, Tenglish-as-OOV | `bilingual` branch, pending GRU |
| 3 | **Morphology-aware Telugu** (stem trie + suffix FST + morpheme LM) | Telugu coverage/prediction/autocorrect | planned |
| 4 | **Tenglish compiled weighted FST** (Dakshina/Aksharantar) | arbitrary-input transliteration | planned |
| 5 | **English dictionary growth** — Wikipedia + Leipzig (freq/n-grams), Wiktionary + WordNet (validity ceiling); decouple validity from frequency | 60k→100k+, register breadth | planned |
| 6 | **Settings surface** — number row, key sound, dictation, autocorrect toggle, one-handed/resize | "not a finished keyboard" gaps | planned |
| 7 | **Real device measurement matrix** (n-gram vs neural; p50/95/99; peak RAM; 30-min jetsam) | converts "instrumented" gates to pass/fail | planned |

**Sequencing:** GRU trained (Colab) → in-trie integration → bilingual on branch →
measure the combined lift. The GRU's real accuracy upgrade (targeting the 85.6%→~95%
oracle gap, ≈ +5–10 pt top-1 on hard inputs) needs the distilled checkpoint + in-trie
wiring; the Core ML stateful export is deferred until then (don't ship an undertrained model).

---

## Session log (what changed)

- **Autocorrect (main):** contraction class fix — preserve typed trailing `s`
  (`thads`→`that's`); `id`→`I'd` at sentence start, `This id`→`is` by context, `your id`
  stays noun. Test-guarded.
- **Plan 1 (main):** context-aware next-char priors (key-target bias uses in-context ranking).
- **UI (main):** row pitch → Apple's measured **54 pt**; Telugu key/glyph scaling; live
  `#Preview`; neural on/off toggle + last-word candidate-ranking diagnostics page.
- **Diagnostics (main):** `#3` pick/replace instrumentation (captures the misfiring transaction).
- **GRU pipeline (main):** `KeyboardGRULM` + train/distill/eval + `prepare_gru_finetune.py`
  + `test_gru_model.py` + **`train_gru_colab.sh`** (CUDA, tqdm). Verified: trains, fine-tune
  took messaging top-1 **8.5%→20.2%**, `forward_step==forward` (drift ~1e-6). Colab OOM fixed
  (batch right-sized for T4).
- **Git:** committed to `main`; `bilingual` branch created off clean `main`.

### Open questions / known items
- **#3 "pick deletes the word"** — not reproduced yet; instrumentation added, awaiting a repro.
- **#2 Tenglish revert** — the mechanism is proven correct by an existing test; re-verify on device.
- **Don't discard the 10.6M** until the GRU is distilled *and* validated; then it's an offline
  asset, not a shipping component.
- **Context length:** the GRU is recurrent — 32 is only training packing; deployment lever is
  short fed-context + state reset at message boundaries.
