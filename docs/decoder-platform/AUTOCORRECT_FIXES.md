# English autocorrect fixes (27 Oct 2026)

Four changes in `native/DecoderCore`. They came from a head-to-head benchmark against CoreV4: 61,775 requests per engine. Full report and raw data are in `/Users/meherdeepak/Downloads/CoreV4/analysis/autocorrect-comparison-2026-10-27/REPORT.md`.

1. **Admissible trie pruning.** `PackedLexicon::search` and `MutableTrie::search` pruned a branch on its DP-row minimum. A transposition reaches back two rows, so that is not a lower bound. Example: `hte` never produced "the". They now prune on `min(rowMin, parentRowMin + transpositionCost)`.
2. **Swapped first letters.** `firstLetterPenalty` takes the typed and candidate second letters. A candidate starting with the typed first two letters swapped pays 0.75 instead of 2.5 for words of 5+ letters (`ocokies`→"cookies"). Other first-letter differences keep 2.5. Discounting neighbouring keys, or any candidate starting with the typed second letter, caused regressions (`qorrwctuon`→"affection", `bcome`→"come").
   * The trie roots use the discount as a provisional bound and settle it at depth 2.
   * Retained-search seeds include the typed second letter, which is part of the session reuse key.
3. **Plural before possessive.** A winner is promoted for a trailing typed *s* only if the typed word is closer to `winner+s`. The plural is then preferred over the possessive: `minuts`→"minutes", not "minute's"; `muts` stays "must".
4. **No inflection swaps.** The real-word gate never replaces a valid word with its own regular inflection (`tests`→`test`, `bases`→`base`). This applies to bases of 3+ letters only, with the precise rules in `inflection()`.

**Measured effect** (iOS before → after; CoreV4 US-74k for reference):

| | Before | After | CoreV4 US-74k |
|---|---|---|---|
| Synthetic typos fixed | 73.7% | 78.5% | 81.5% |
| Miscorrections | 19.2% | 14.7% | 17.8% |
| Transpositions fixed | 66% | 85% | — |
| Real misspellings fixed | 80.2% | 81.5% | — |
| False corrections of correct words | 0.88 / 0.92% | 0.59 / 0.61% | — |
| Plurals stripped | 48 | 0 | — |
| Real-word errors fixed | 38.5% | 36.5% | — |

Prediction is unchanged, and per-keystroke typing cost is unchanged in total.

**Goldens.** 10 of 132 shared-engine decode goldens changed. Only one is visible: `whens` is no longer corrected to "when", and "when's" is now the first suggestion. The rest differ only in lower-ranked candidate rows. All 60 Glide goldens are unchanged.

The regenerator, `ioskeyboard-fixes/gengolden.cpp` + `assemble_golden.py` in the report folder, reproduces the previous file byte-for-byte from the previous engine.

**Swift mirror.** The Swift copies mirror all four rules:
* `Trie`/`SwiftTrie.firstLetterPenaltyPolicy`;
* the `SwiftTrie` and packed `trieSearch` (provisional root penalty, admissible pruning);
* `incrementalSeeds(typedSecond:)`, plus a `KBDecoderBridge` overload carrying `typedSecond`;
* `IncrementalDecodeSession`;
* the retained-session reuse key in `KeyboardEngine+Suggestions.swift`;
* `correctionReference`.

With the `.cpp` backend, the GRU tier still runs the Swift pipeline over native search, so the seed and session changes also reach that production path. Its correction already goes through native `KBRanking`.

**Simulator run.** iPhone 17 Pro, Debug: 135/136 tests pass, including `NativeSearchParityTests`, `CorrectionCalibrationTests`, `NativeCandidateGenerationTests` and `SevereTypoBenchmark`. The one failure is `suggestionPassThroughBoundaryDoesNotMoveKeyGeometry`. It expects the bordered `primaryBackground` view, which the separate in-progress `SuggestionBar.swift` edit removes.

**Shortlist cap (round 2).** `EngineSession::score` keeps at most 16 completion-only rows before the 32-row pre-LM shortlist, so zero-cost completions can no longer crowd out corrections (`tat`→"that" restored).

| | Before | After |
|---|---|---|
| Real-word errors fixed | 36.5% | 41.3% (p = 2e-18) |
| Keystroke savings | 46.61% | 46.32% |

Typo accuracy, false corrections and prediction are unchanged. `kb::shortlist` and the Swift/GRU pipeline are unchanged. 8 goldens changed, none visibly.

**Blocked words excluded during generation (round 4).**

* The dictionary marks its 279 blocked words as a load-time word-ID bitset (`PackedLexicon::installBlocked`).
* Search, completions, retained seeds, Glide anchors and decoding, and LM successors never emit them. Phrases check the joined phrase.
* The typed literal stays available.
* Downstream per-candidate safety checks are removed in C++ and on the Swift Glide/GRU paths. Ranking applies only the residual in-dictionary demote penalties, none for this pack.
* The closest blocked match's cost still bounds broad recovery, so `biitch` is left alone rather than corrected to "both".
* Outputs, goldens and C++ latency are unchanged. The Swift reference mirrors all of it.

**Open items:**

* Ranking: recovered typo targets are generated and shortlisted but lose the top spot. Next: missing-letter channel cost.
* The GRU-tier Swift pipeline does not have the completion cap.
* First-letter omissions (`bove`→above, `nstead`→instead) are still rarely fixed.
