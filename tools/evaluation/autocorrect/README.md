# Autocorrect benchmark (shared C++ engine vs CoreV4)

Measures autocorrection, suggestions and prediction of `native/DecoderCore` on the same
61,775 requests as the 27 Oct 2026 CoreV4 comparison
(`CoreV4/analysis/autocorrect-comparison-2026-10-27`), plus four public misspelling lists.

## Data

| Path | What |
|---|---|
| `corpus/cases.tsv`, `cases-meta.json` | ECPS real misspellings (CoreV4's data), MacKenzie synthetic typos, clean words, hard words, contractions, prediction. Built by `make_corpus.py` (needs a CoreV4 checkout, `COREV4=`). |
| `external/*.dat` → `corpus/ext-cases.*` | Birkbeck, Holbrook, Aspell, Wikipedia lists from https://www.dcs.bbk.ac.uk/~ROGER/corpora.html, filtered by `make_external.py`. **Held-out only.** |
| `corpus/*.taps.tsv` | The same rows with simulated touches (`make_taps.py`). |
| `corpus/keystrokes.tsv` | 4,000 real misspellings typed one letter at a time (typing latency). |

`corpus/`, `external/`, `results/` and `bin/` are not committed.

Every set is split in half by a hash of the target word. **Tune on `tune`, report `held`.**

## Commands

```
python3 evaluate.py build [--bin NAME] [--tuning]   # --tuning: constants read from KB_<name>
python3 evaluate.py run NAME [--bin NAME] [--quick] [--taps] [--diag]
python3 evaluate.py score NAME [--vs baseline] [--split held|tune|all]
python3 evaluate.py golden [--write]                # regenerate decode goldens, print visible changes
python3 evaluate.py core                            # CoreV4 on the external lists
python3 tune.py --bin ios-tune [--grid JSON] [--start JSON]   # coordinate search, tune half
python3 gate_sweep.py "oov,realWord,rescue,gap,minGap,maxCost" ...
python3 latency_tradeoff.py BIN '{"deletionCost": 1.1}' ...   # typing latency + accuracy
python3 funnel.py results/NAME.diag.jsonl            # where the target is lost
```

`score` exits 1 when a guardrail gets worse (paired McNemar p < 0.05): false corrections,
hard words, plurals, real-word errors, contractions, prediction, keystroke savings, latency.
Its latency rows compare against whatever machine load the reference run had; for latency
decisions use `latency_tradeoff.py` or the keystroke test on an idle machine, alternating builds.

## Results (held-out half)

| | 27 Oct before | 27 Oct after | 31 Oct | CoreV4 |
|---|---|---|---|---|
| ECPS real misspellings fixed | 79.6% | 83.6% | 89.3% | 88.0% |
| ECPS target in top 3 | 89.4% | 92.5% | 94.8% | 93.6% |
| ECPS left uncorrected | | 3.0% | 3.1% | 0.8% |
| Synthetic typos fixed | 78.9% | 85.8% | 88.7% | 81.0% |
| Synthetic in top 3 | 85.5% | 92.2% | 93.5% | 90.5% |
| Wikipedia fixed (top 3) | 68.4% | 71.8% (90.3%) | 79.2% (92.8%) | 83.6% (94.3%) |
| Birkbeck / Holbrook / Aspell fixed | 35.5 / 35.8 / 48.1% | 41.3 / 39.8 / 54.4% | 40.2 / 45.3 / 54.4% | 38.6 / 38.4 / 54.4% |
| False corrections (ECPS correct words) | 0.70% | 0.58% | 0.45% | 0.88% |
| Unknown names changed (make_keep.py) | 81.7%* | 81.2% | 75.0% | 80.1% |
| Rare dictionary words changed | 57.0%* | 49.1% | 39.1% | 42.3% |
| Unknown slang changed (n = 8) | | 100% | 100% | 87.5% |
| Real-word errors fixed | 42.4% | 44.6% | 44.2% | 0.3% |
| Typing p50 / p95 / p99, letters 5+ (ms) | 0.66 / 3.24 / 3.58 | 0.67 / 3.88 / 5.38 | 0.73 / 4.05 / 5.80 | |
| Typo request p50 / p95 / p99 (ms) | | 0.44 / 5.21 / 6.28 | 0.50 / 5.73 / 6.97 | |

\* all rows, not the held half. Constants fitted by `tune.py` are documented where they are
defined (`native/DecoderCore/include/SpatialModel.hpp`, `CandidateGeneration.hpp`, `Ranking.hpp`).

### 28 Oct: spelling errors, and an audit of what the tests could not see

Tuned on the tune halves of ECPS, synthetic, the Wikipedia list (`tune.py --wiki`) and the
should-not-change set; Birkbeck, Holbrook and Aspell were not used for tuning.

**Audit.** An earlier version of this round (margin -6) reported Wikipedia 86.3% fixed, ahead of
CoreV4. Every misspelling set rewards changing; the "should not change" guardrails were dictionary
words (MacKenzie clean, ECPS correct: 61 of 22,136 rows are not in the iOS vocabulary), so they
only test the real-word gate, while the margin change only affects typed non-words. Measured on
`make_keep.py` (names and words missing from the iOS vocabulary, from macOS /usr/share/dict,
never tuned on), that version changed 84.5% of unknown names (27 Oct: 76.3%, CoreV4: 78.8%).
`tune.py` now rejects any setting that changes more tune-half names than the reference, and
`score` reports the held half as guardrails. Other known biases: the 95-word hard set is not split
and was used in tuning; ECPS repeats some typos many times (`Xscape` x14), so McNemar p-values are
optimistic; the recovery-weight idea came from seeing a regression on held-out Birkbeck (the value
was then picked on tune data), and the real-word regression of fix A below was first seen on the
held half.

**What changed:**
- **Channel weight 4** (`channelWeight`) with non-word margin -0.5 (`oovMargin`): spelling distance
  outweighs frequency (`recident` -> resident, not president). Within the names guardrail; lower
  margins fix up to 2 points more misspellings and change up to 12 points more names (a product
  decision, not a tuning result).
- **The gate keeps weight 1 where the old calibration was right**: real words
  (`realWordChannelWeight`) and recovery-only winners (`recoveryChannelWeight`).
- **A non-word is judged by each candidate's correction cost**, not as a cost-0 completion
  (`successfull` -> successful, not "successfully"; unknown names were autocompleted the same way).
  The real-word gate keeps the completion cost it was calibrated with (`wit` -> with) and only
  weighs candidates within its 1.6 cost cap (`realWordCloseOnly`).
- **Splits**: a missing-space split needs margin 3 (`splitCorrectionMargin`, `iamhere` is not
  "ia here"); a split that fails it gives way to the best single word (`sacreligious`). A real-word
  fix adds at most one letter (`dog` -> doggy).
- **Spelling costs**: doubled letters (`posess`, `excell`: 0.3 / 0.6, same letter on both sides only),
  vowel for vowel 1.5 (`speach`), not at the typed first letter. First-letter vowel and c/k/s/z
  confusions are tunable but off: they overflowed the retained search's seed cap.
- Latency (alternated with the 27 Oct build, 31 Oct): +9% p50 / +5% p95 / +8% p99 per keystroke on
  letters 5+, +10% p95 per typo request; most of it is the doubled-letter branch in the retained
  search's inner loop.
- **31 Oct, first letters and an extra leading key** (both checked against the names guardrail):
  first letters a speller confuses (`emminent` -> imminent) are searched in a narrow pass over
  just those roots (`firstVowelSubstitutionCost` 1.5); the retained search's seeds are unchanged
  (`seedFirstLetterCost`). It mostly adds the target to the top 3: the closer word (eminent)
  still wins. A c/k/s/z first-letter discount (`krust`) changed more names and stays off. A
  neighbouring key typed before a non-word (`vfell` -> fell) costs `extraLeadingKeyCost` 1.6 plus
  the rest: synthetic fixed +0.5 points held-out (wrong first letter 71.9 -> 75.1%), nothing
  more changed on the should-not-change sets.
- Worse than 27 Oct: Birkbeck fixed 41.3 -> 40.2% (top 3 55.0 -> 59.7%), synthetic left uncorrected
  0.9 -> 1.6%: the conservative gate leaves more typos as typed.
